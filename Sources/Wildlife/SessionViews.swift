import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WildlifeCore

struct ManagerView: View {
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @ObservedObject var integrations: IntegrationManager
    @ObservedObject var runtime: AppRuntime
    @Environment(\.openSettings) private var openSettings
    @State private var showingOnboarding = false

    var body: some View {
        HSplitView {
            SessionBoard(repository: repository, settings: settings)
                .frame(minWidth: 720)
            Group {
                if let session = repository.selectedSession {
                    SessionDetail(session: session, repository: repository, settings: settings)
                        .id(session.stableKey)
                } else {
                    ContentUnavailableView(
                        "Select a session",
                        systemImage: "pawprint",
                        description: Text("Titles, notes, keys, and resume actions appear here.")
                    )
                }
            }
            .frame(minWidth: 330, idealWidth: 390)
        }
        .navigationTitle("Wildlife")
        .searchable(text: $repository.searchText, placement: .toolbar, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { openSettings() } label: { Label("Settings", systemImage: "gear") }
            }
        }
        .frame(minWidth: 1_100, minHeight: 650)
        .onAppear {
            runtime.start()
            showingOnboarding = !settings.onboardingCompleted
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(settings: settings, integrations: integrations) {
                showingOnboarding = false
            }
        }
    }
}

@MainActor
private final class SessionDragCoordinator: ObservableObject {
    @Published private(set) var draggedKey: String?
    @Published private(set) var previewBacklogKeys: [String] = []
    @Published private(set) var targetedBucket: WorkflowBucket?

    private var originalBacklogKeys: [String] = []

    func begin(_ session: SessionRecord, repository: SessionRepository) {
        draggedKey = session.stableKey
        originalBacklogKeys = repository.sessions
            .filter { $0.workflow == .backlog }
            .sorted { $0.backlogOrder < $1.backlogOrder }
            .map(\.stableKey)
        previewBacklogKeys = originalBacklogKeys
        targetedBucket = nil
    }

    func canDrop(into bucket: WorkflowBucket, repository: SessionRepository) -> Bool {
        guard bucket != .inProgress,
              let draggedKey,
              let session = repository.sessions.first(where: { $0.stableKey == draggedKey }) else {
            return false
        }
        return session.workflow != .inProgress
    }

    func enter(
        _ bucket: WorkflowBucket,
        before targetKey: String?,
        repository: SessionRepository
    ) {
        guard canDrop(into: bucket, repository: repository), let draggedKey else { return }
        targetedBucket = bucket
        if bucket == .backlog {
            previewBacklogKeys = BacklogOrderPlanner.moving(
                draggedKey,
                before: targetKey,
                in: originalBacklogKeys
            )
        } else {
            previewBacklogKeys = originalBacklogKeys
        }
    }

    func leave(_ bucket: WorkflowBucket) {
        guard targetedBucket == bucket else { return }
        targetedBucket = nil
        previewBacklogKeys = originalBacklogKeys
    }

    func performDrop(into bucket: WorkflowBucket, repository: SessionRepository) -> Bool {
        guard canDrop(into: bucket, repository: repository), let draggedKey else {
            reset()
            return false
        }
        let order = bucket == .backlog ? previewBacklogKeys : nil
        repository.commitDrop(sessionKey: draggedKey, to: bucket, backlogOrder: order)
        reset()
        return true
    }

    func records(in bucket: WorkflowBucket, repository: SessionRepository) -> [SessionRecord] {
        let regularRecords = repository.sessions(in: bucket)
        guard bucket == .backlog, targetedBucket == .backlog else { return regularRecords }

        let visibleKeys = Set(regularRecords.map(\.stableKey))
        let recordsByKey = Dictionary(uniqueKeysWithValues: repository.sessions.map { ($0.stableKey, $0) })
        return previewBacklogKeys.compactMap { key in
            guard visibleKeys.contains(key) || key == draggedKey else { return nil }
            return recordsByKey[key]
        }
    }

    private func reset() {
        draggedKey = nil
        previewBacklogKeys = []
        originalBacklogKeys = []
        targetedBucket = nil
    }
}

struct SessionBoard: View {
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @StateObject private var dragCoordinator = SessionDragCoordinator()

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(WorkflowBucket.allCases) { bucket in
                    SessionColumn(
                        bucket: bucket,
                        repository: repository,
                        settings: settings,
                        dragCoordinator: dragCoordinator
                    )
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SessionCardFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

struct SessionColumn: View {
    let bucket: WorkflowBucket
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @ObservedObject fileprivate var dragCoordinator: SessionDragCoordinator
    @State private var cardFrames: [String: CGRect] = [:]

    private var records: [SessionRecord] {
        dragCoordinator.records(in: bucket, repository: repository)
    }

    private var coordinateSpaceName: String { "session-column-\(bucket.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(bucket.displayName).font(.headline)
                Spacer()
                Text("\(records.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(records, id: \.stableKey) { session in
                        VStack(spacing: 0) {
                            if showsInsertionMarker(before: session) {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(height: 3)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 6)
                            }
                            SessionCard(session: session, repository: repository, settings: settings)
                                .opacity(dragCoordinator.draggedKey == session.stableKey ? 0.38 : 1)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: SessionCardFramePreferenceKey.self,
                                            value: [session.stableKey: proxy.frame(in: .named(coordinateSpaceName))]
                                        )
                                    }
                                }
                                .sessionDragSource(
                                    session: session,
                                    repository: repository,
                                    coordinator: dragCoordinator
                                )
                        }
                    }
                    if records.isEmpty {
                        Text(emptyMessage)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                }
                .animation(.snappy(duration: 0.2), value: records.map(\.stableKey))
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    dragCoordinator.targetedBucket == bucket ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(SessionCardFramePreferenceKey.self) { cardFrames = $0 }
        .onDrop(
            of: [UTType.utf8PlainText],
            delegate: SessionColumnDropDelegate(
                bucket: bucket,
                records: records,
                cardFrames: cardFrames,
                repository: repository,
                coordinator: dragCoordinator
            )
        )
    }

    private func showsInsertionMarker(before session: SessionRecord) -> Bool {
        bucket == .backlog &&
            dragCoordinator.targetedBucket == .backlog &&
            dragCoordinator.draggedKey == session.stableKey
    }

    private var emptyMessage: String {
        switch bucket {
        case .inProgress: "New terminal sessions appear here"
        case .backlog: "Drop completed work here"
        case .completed: "Ended sessions appear here"
        }
    }
}

private struct SessionColumnDropDelegate: DropDelegate {
    let bucket: WorkflowBucket
    let records: [SessionRecord]
    let cardFrames: [String: CGRect]
    let repository: SessionRepository
    let coordinator: SessionDragCoordinator

    func validateDrop(info: DropInfo) -> Bool {
        coordinator.canDrop(into: bucket, repository: repository)
    }

    func dropEntered(info: DropInfo) {
        updatePreview(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard coordinator.canDrop(into: bucket, repository: repository) else {
            return DropProposal(operation: .forbidden)
        }
        updatePreview(at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        coordinator.leave(bucket)
    }

    func performDrop(info: DropInfo) -> Bool {
        coordinator.performDrop(into: bucket, repository: repository)
    }

    private func updatePreview(at location: CGPoint) {
        let targetKey: String?
        if bucket == .backlog {
            targetKey = records
                .filter { $0.stableKey != coordinator.draggedKey }
                .first { session in
                    guard let frame = cardFrames[session.stableKey] else { return false }
                    return location.y < frame.midY
                }?
                .stableKey
        } else {
            targetKey = nil
        }
        coordinator.enter(bucket, before: targetKey, repository: repository)
    }
}

private extension View {
    @ViewBuilder
    func sessionDragSource(
        session: SessionRecord,
        repository: SessionRepository,
        coordinator: SessionDragCoordinator
    ) -> some View {
        if session.workflow == .inProgress {
            self
        } else {
            onDrag {
                coordinator.begin(session, repository: repository)
                return NSItemProvider(object: session.stableKey as NSString)
            }
        }
    }
}

struct SessionCard: View {
    let session: SessionRecord
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @State private var copied = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(session.emoji).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(session.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(status: session.runtimeStatus)
            }
            if session.workflow == .inProgress {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(session.runtimeStatus.attentionColor)
            } else {
                HStack {
                    Text(session.sessionID)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        repository.copyKey(session)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy session key")
                }
                .foregroundStyle(.secondary)
            }
            Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(11)
        .contentShape(Rectangle())
        .background(
            repository.selectedSessionKey == session.stableKey
                ? Color.accentColor.opacity(0.17)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .onTapGesture { repository.selectedSessionKey = session.stableKey }
        .contextMenu {
            SessionContextMenu(
                session: session,
                repository: repository,
                settings: settings,
                confirmingDelete: $confirmingDelete
            )
        }
        .confirmationDialog("Remove this Wildlife record?", isPresented: $confirmingDelete) {
            Button("Remove Record", role: .destructive) { repository.delete(session) }
        } message: {
            Text("The Codex or Claude session and transcript remain untouched.")
        }
    }

    private var statusLine: String {
        if session.runtimeStatus == .runningTool, let tool = session.toolName { return "Running \(tool)" }
        if session.activeSubagentCount > 0 { return "\(session.runtimeStatus.displayName) · \(session.activeSubagentCount) subagent(s)" }
        return session.runtimeStatus.displayName
    }
}

private struct SessionContextMenu: View {
    let session: SessionRecord
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @Binding var confirmingDelete: Bool
    var report: (String) -> Void = { _ in }

    var body: some View {
        Button("Copy Session Key") {
            repository.copyKey(session)
            report("Session key copied")
        }
        Button("Copy Resume Command") {
            do {
                try repository.copyResumeCommand(session, settings: settings)
                report("Resume command copied")
            } catch {
                report(error.localizedDescription)
            }
        }
        if session.workflow == .completed {
            Divider()
            Button("Move to Backlog") { repository.move(session, to: .backlog) }
        } else if session.workflow == .backlog {
            Divider()
            Button("Mark Completed") { repository.move(session, to: .completed) }
        }
        Divider()
        Button("Remove from Wildlife", role: .destructive) { confirmingDelete = true }
    }
}

struct StatusDot: View {
    let status: RuntimeStatus

    var body: some View {
        Circle()
            .fill(status.attentionColor)
            .frame(width: 8, height: 8)
            .shadow(color: status.attentionColor.opacity(0.6), radius: status.priority <= 1 ? 4 : 0)
            .accessibilityLabel(status.displayName)
    }
}

extension RuntimeStatus {
    var attentionColor: Color {
        switch self {
        case .waitingForApproval, .error: .orange
        case .processing, .runningTool, .compacting, .starting: .green
        case .waitingForInput: .blue
        case .ended: .secondary
        }
    }
}

private struct InlineSessionIdentityEditor: View {
    private enum Field: Hashable { case emoji, title }

    let session: SessionRecord
    @ObservedObject var repository: SessionRepository
    @State private var editingField: Field?
    @State private var titleDraft = ""
    @State private var emojiDraft = ""
    @State private var originalDraft = ""
    @State private var emojiError: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                emojiControl
                titleControl
            }
            if let emojiError {
                Text(emojiError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            guard newValue == nil, let oldValue, editingField == oldValue else { return }
            commit(oldValue)
        }
    }

    @ViewBuilder
    private var emojiControl: some View {
        if editingField == .emoji {
            TextField("Emoji", text: $emojiDraft)
                .font(.system(size: 38))
                .textFieldStyle(.plain)
                .frame(width: 54)
                .focused($focusedField, equals: .emoji)
                .onSubmit { commit(.emoji) }
                .onExitCommand { cancel() }
        } else {
            Text(session.emoji)
                .font(.system(size: 44))
                .contentShape(Rectangle())
                .onTapGesture { beginEditing(.emoji) }
                .help("Click to edit emoji")
        }
    }

    @ViewBuilder
    private var titleControl: some View {
        if editingField == .title {
            TextField("Session title", text: $titleDraft)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .title)
                .onSubmit { commit(.title) }
                .onExitCommand { cancel() }
        } else {
            Text(session.displayTitle)
                .font(.title2.bold())
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing(.title) }
                .help("Click to edit title")
        }
    }

    private func beginEditing(_ field: Field) {
        emojiError = nil
        editingField = field
        switch field {
        case .emoji:
            emojiDraft = session.emoji
            originalDraft = emojiDraft
        case .title:
            titleDraft = session.customTitle ?? session.displayTitle
            originalDraft = titleDraft
        }
        focusedField = field
    }

    private func commit(_ field: Field) {
        guard editingField == field else { return }
        editingField = nil
        focusedField = nil

        switch field {
        case .emoji:
            guard emojiDraft != originalDraft else { return }
            if let error = repository.updateCustomEmoji(emojiDraft, for: session) {
                emojiDraft = session.emoji
                emojiError = error
            } else {
                emojiError = nil
            }
        case .title:
            guard titleDraft != originalDraft else { return }
            repository.updateCustomTitle(titleDraft, for: session)
        }
    }

    private func cancel() {
        editingField = nil
        focusedField = nil
        emojiDraft = session.emoji
        titleDraft = session.customTitle ?? session.displayTitle
        emojiError = nil
    }
}

struct SessionDetail: View {
    let session: SessionRecord
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @State private var copyMessage: String?
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    InlineSessionIdentityEditor(session: session, repository: repository)
                    Label(session.provider.displayName, systemImage: session.provider == .codex ? "terminal" : "sparkles")
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    SessionContextMenu(
                        session: session,
                        repository: repository,
                        settings: settings,
                        confirmingDelete: $confirmingDelete,
                        report: { copyMessage = $0 }
                    )
                }

                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Project", value: session.cwd)
                        LabeledContent("Session key") {
                            Text(session.sessionID).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Actions") {
                    HStack {
                        Button("Copy key") { repository.copyKey(session); copyMessage = "Session key copied" }
                        Button("Copy resume command") {
                            do {
                                try repository.copyResumeCommand(session, settings: settings)
                                copyMessage = "Resume command copied"
                            } catch {
                                copyMessage = error.localizedDescription
                            }
                        }
                        if session.workflow == .completed {
                            Button("Move to Backlog") { repository.move(session, to: .backlog) }
                        } else if session.workflow == .backlog {
                            Button("Mark Completed") { repository.move(session, to: .completed) }
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox("Notes") {
                    TextEditor(text: Binding(
                        get: { session.notesMarkdown },
                        set: { session.notesMarkdown = $0; repository.save() }
                    ))
                    .font(.body)
                    .frame(minHeight: 220)
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .overlay(alignment: .bottom) {
            if let copyMessage {
                Text(copyMessage)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        self.copyMessage = nil
                    }
            }
        }
        .confirmationDialog("Remove this Wildlife record?", isPresented: $confirmingDelete) {
            Button("Remove Record", role: .destructive) { repository.delete(session) }
        } message: {
            Text("The Codex or Claude session and transcript remain untouched.")
        }
    }
}
