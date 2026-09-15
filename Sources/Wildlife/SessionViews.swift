import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WildlifeCore

struct ManagerView: View {
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @ObservedObject var integrations: IntegrationManager
    @ObservedObject var runtime: AppRuntime
    @EnvironmentObject private var actions: SessionActionController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showingOnboarding = false

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                SessionBoard(repository: repository, settings: settings, runtime: runtime)
                    .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                Divider()
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
                .frame(width: detailSidebarWidth(for: proxy.size.width))
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("Wildlife")
        .searchable(text: $repository.searchText, placement: .toolbar, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .principal) {
                SessionViewToolbar(repository: repository, settings: settings)
            }
            ToolbarItem(placement: .automatic) {
                Button { openSettings() } label: { Label("Settings", systemImage: "gear") }
            }
        }
        .frame(minWidth: 1_100, minHeight: 650)
        .onAppear {
            runtime.start {
                openWindow(id: "manager")
            }
            showingOnboarding = !settings.onboardingCompleted
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(settings: settings, integrations: integrations) {
                showingOnboarding = false
            }
        }
        .confirmationDialog(
            "Resume session in \(settings.preferredTerminal.displayName)?",
            isPresented: Binding(
                get: { pendingResumeSession != nil },
                set: { if !$0 { actions.pendingResumeSessionKey = nil } }
            ),
            presenting: pendingResumeSession
        ) { session in
            Button("Run Resume Command") { actions.confirmResume(session) }
            Button("Cancel", role: .cancel) { actions.pendingResumeSessionKey = nil }
        } message: { session in
            Text((try? actions.renderedResumeCommand(for: session)) ?? "The resume command is invalid.")
        }
        .confirmationDialog(
            "Terminate this session?",
            isPresented: Binding(
                get: { pendingTerminationSession != nil },
                set: { if !$0 { actions.pendingTerminationSessionKey = nil } }
            ),
            presenting: pendingTerminationSession
        ) { session in
            Button("Terminate Session", role: .destructive) { actions.confirmTermination(session) }
            Button("Cancel", role: .cancel) { actions.pendingTerminationSessionKey = nil }
        } message: { _ in
            Text("Wildlife will send SIGTERM to the verified agent process. The transcript will remain available to resume later.")
        }
        .overlay(alignment: .bottom) {
            if let message = actions.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        if actions.message == message { actions.message = nil }
                    }
            }
        }
    }

    private var pendingResumeSession: SessionRecord? {
        actions.pendingResumeSessionKey.flatMap(repository.session(forKey:))
    }

    private var pendingTerminationSession: SessionRecord? {
        actions.pendingTerminationSessionKey.flatMap(repository.session(forKey:))
    }

    private func detailSidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        min(390, max(330, windowWidth * 0.30))
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
    @ObservedObject var runtime: AppRuntime
    @StateObject private var dragCoordinator = SessionDragCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            if !conflictingWorktrees.isEmpty {
                Label(
                    "Multiple active sessions share \(conflictingWorktrees.count == 1 ? "a worktree" : "worktrees")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(WorkflowBucket.allCases) { bucket in
                    SessionColumn(
                        bucket: bucket,
                        repository: repository,
                        settings: settings,
                        dragCoordinator: dragCoordinator
                    )
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            if !repository.includesOlderSessions || runtime.isImportingOlderHistory {
                Divider()
                HStack(spacing: 10) {
                    Text("Showing active sessions and the last 7 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if runtime.isImportingOlderHistory {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading older sessions…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Load older sessions") { runtime.importOlderHistory() }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var conflictingWorktrees: Set<String> {
        SessionOrganization.conflictingWorktreeKeys(in: repository.activeSessions)
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
    @State private var collapsedProjectKeys = Set<String>()

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
                    recordsContent
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
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                records: visuallyOrderedRecords,
                cardFrames: cardFrames,
                repository: repository,
                coordinator: dragCoordinator
            )
        )
    }

    @ViewBuilder
    private var recordsContent: some View {
        if settings.groupByProject {
            ForEach(projectGroups, id: \.key) { group in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { !collapsedProjectKeys.contains(group.key) },
                        set: { expanded in
                            if expanded { collapsedProjectKeys.remove(group.key) }
                            else { collapsedProjectKeys.insert(group.key) }
                        }
                    )
                ) {
                    VStack(spacing: 9) {
                        ForEach(group.records, id: \.stableKey) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.top, 7)
                } label: {
                    HStack {
                        Text(group.name)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Spacer()
                        Text("\(group.records.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 3)
            }
        } else {
            ForEach(records, id: \.stableKey) { session in
                sessionRow(session)
            }
        }
    }

    private var projectGroups: [(key: String, name: String, records: [SessionRecord])] {
        let grouped = Dictionary(grouping: records, by: \.projectKey)
        return grouped.map { key, records in
            (key: key, name: records.first?.projectDisplayName ?? "Unknown Project", records: records)
        }.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var visuallyOrderedRecords: [SessionRecord] {
        settings.groupByProject ? projectGroups.flatMap(\.records) : records
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
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
    @EnvironmentObject private var actions: SessionActionController
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
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            HStack(spacing: 5) {
                if let metadata = session.projectMetadata {
                    Label(metadata.branch, systemImage: "arrow.triangle.branch")
                    if hasWorktreeConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Another active session uses this worktree")
                    }
                } else {
                    Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            if !session.tags.isEmpty {
                Text(session.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .contentShape(Rectangle())
        .background(
            repository.selectedSessionKey == session.stableKey
                ? Color.accentColor.opacity(0.17)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { gesture in
                    repository.selectedSessionKey = session.stableKey
                    if case .first = gesture, session.workflow == .inProgress {
                        _ = actions.focus(session)
                    }
                }
        )
        .contextMenu {
            SessionActionItems(
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

    private var hasWorktreeConflict: Bool {
        guard let path = session.projectMetadata?.worktreeRoot else { return false }
        return SessionOrganization.conflictingWorktreeKeys(in: repository.activeSessions).contains(path)
    }
}

private struct SessionActionItems: View {
    let session: SessionRecord
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var actions: SessionActionController
    @EnvironmentObject private var runtime: AppRuntime
    @Binding var confirmingDelete: Bool
    var report: (String) -> Void = { _ in }

    var body: some View {
        if session.workflow == .inProgress {
            Button { _ = actions.focus(session) } label: {
                Label("Focus Terminal", systemImage: "scope")
            }
            Button(role: .destructive) {
                actions.requestTermination(session)
            } label: {
                Label(
                    actions.isTerminationRequested(session) ? "Terminating…" : "Terminate Session…",
                    systemImage: "stop.circle"
                )
            }
            .disabled(actions.isTerminationRequested(session))
        } else {
            Button { actions.requestResume(session) } label: {
                Label("Resume Session…", systemImage: "play.circle")
            }
        }
        Button { actions.revealRepository(session) } label: {
            Label("Reveal Repository in Finder", systemImage: "folder")
        }
        Button { actions.openInTerminal(session) } label: {
            Label("Open Project in Terminal", systemImage: "terminal")
        }
        Button { actions.copyPath(session) } label: {
            Label("Copy Project Path", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            repository.copyKey(session)
            report("Session key copied")
        } label: {
            Label("Copy Session Key", systemImage: "key")
        }
        Button {
            do {
                try repository.copyResumeCommand(session, settings: settings)
                report("Resume command copied")
            } catch {
                report(error.localizedDescription)
            }
        } label: {
            Label("Copy Resume Command", systemImage: "terminal.fill")
        }
        Button { repository.togglePinned(session) } label: {
            Label(
                session.isPinned ? "Unpin" : "Pin",
                systemImage: session.isPinned ? "pin.slash" : "pin"
            )
        }
        if session.workflow != .inProgress {
            Button {
                repository.setArchived(session.archivedAt == nil, for: session)
            } label: {
                Label(
                    session.archivedAt == nil ? "Archive" : "Restore",
                    systemImage: session.archivedAt == nil ? "archivebox" : "arrow.uturn.backward"
                )
            }
        }
        if session.attentionReason() != nil {
            Menu {
                Button("15 Minutes") { runtime.snooze(session, until: Date().addingTimeInterval(900)) }
                Button("1 Hour") { runtime.snooze(session, until: Date().addingTimeInterval(3_600)) }
                Button("Until Tomorrow") { runtime.snooze(session, until: tomorrowMorning) }
            } label: {
                Label("Snooze Attention", systemImage: "clock")
            }
        }
        if session.workflow == .completed {
            Divider()
            Button { repository.move(session, to: .backlog) } label: {
                Label("Move to Backlog", systemImage: "tray")
            }
        } else if session.workflow == .backlog {
            Divider()
            Button { repository.move(session, to: .completed) } label: {
                Label("Mark Completed", systemImage: "checkmark.circle")
            }
        }
        Divider()
        Button(role: .destructive) { confirmingDelete = true } label: {
            Label("Remove from Wildlife", systemImage: "trash")
        }
    }

    private var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
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
    let session: SessionRecord
    @ObservedObject var repository: SessionRepository
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var originalTitleDraft = ""
    @State private var emojiError: String?
    @State private var emojiPickerRequestID = 0
    @FocusState private var isTitleFocused: Bool

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
        .onChange(of: isTitleFocused) { oldValue, newValue in
            guard oldValue, !newValue, isEditingTitle else { return }
            commitTitle()
        }
    }

    private var emojiControl: some View {
        Button(action: openEmojiPicker) {
            Text(session.emoji)
                .font(.system(size: 44))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose session emoji")
        .accessibilityLabel("Change session emoji")
        .background {
            EmojiCharacterPickerBridge(requestID: emojiPickerRequestID) { selection in
                applyEmoji(selection)
            }
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var titleControl: some View {
        if isEditingTitle {
            TextField("Session title", text: $titleDraft)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .focused($isTitleFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { cancelTitleEditing() }
        } else {
            Text(session.displayTitle)
                .font(.title2.bold())
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture { beginTitleEditing() }
                .help("Click to edit title")
        }
    }

    private func openEmojiPicker() {
        emojiError = nil
        if isEditingTitle { commitTitle() }
        emojiPickerRequestID &+= 1
    }

    private func applyEmoji(_ emoji: String) {
        guard emoji != session.emoji else {
            emojiError = nil
            return
        }
        emojiError = repository.updateCustomEmoji(emoji, for: session)
    }

    private func beginTitleEditing() {
        emojiError = nil
        titleDraft = session.customTitle ?? session.displayTitle
        originalTitleDraft = titleDraft
        isEditingTitle = true
        isTitleFocused = true
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        isTitleFocused = false
        guard titleDraft != originalTitleDraft else { return }
        repository.updateCustomTitle(titleDraft, for: session)
    }

    private func cancelTitleEditing() {
        isEditingTitle = false
        isTitleFocused = false
        titleDraft = session.customTitle ?? session.displayTitle
        emojiError = nil
    }
}

private struct EmojiCharacterPickerBridge: NSViewRepresentable {
    let requestID: Int
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> EmojiCaptureTextView {
        let view = EmojiCaptureTextView()
        view.drawsBackground = false
        view.isEditable = true
        view.isSelectable = true
        view.textColor = .clear
        view.insertionPointColor = .clear
        view.onInsert = onSelection
        return view
    }

    func updateNSView(_ nsView: EmojiCaptureTextView, context: Context) {
        nsView.onInsert = onSelection
        guard context.coordinator.presentedRequestID != requestID else { return }
        context.coordinator.presentedRequestID = requestID
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let window = nsView.window else { return }
            window.makeFirstResponder(nsView)
            NSApplication.shared.orderFrontCharacterPalette(nil)
        }
    }

    final class Coordinator {
        var presentedRequestID = 0
    }
}

private final class EmojiCaptureTextView: NSTextView {
    var onInsert: ((String) -> Void)?

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let value: String
        if let attributedString = insertString as? NSAttributedString {
            value = attributedString.string
        } else if let string = insertString as? String {
            value = string
        } else {
            return
        }
        guard !value.isEmpty else { return }
        onInsert?(value)
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
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        InlineSessionIdentityEditor(session: session, repository: repository)
                        Label(
                            session.provider.displayName,
                            systemImage: session.provider == .codex ? "terminal" : "sparkles"
                        )
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        SessionActionItems(
                            session: session,
                            repository: repository,
                            settings: settings,
                            confirmingDelete: $confirmingDelete,
                            report: { copyMessage = $0 }
                        )
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .contextMenu {
                    SessionActionItems(
                        session: session,
                        repository: repository,
                        settings: settings,
                        confirmingDelete: $confirmingDelete,
                        report: { copyMessage = $0 }
                    )
                }

                GroupBox("Details") {
                    VStack(alignment: .leading, spacing: 0) {
                        SessionPropertyRow(
                            key: "Repository",
                            value: session.projectMetadata?.repositoryRoot ?? session.cwd
                        )
                        Divider()
                        if let metadata = session.projectMetadata {
                            SessionPropertyRow(key: "Worktree", value: metadata.worktreeRoot)
                            Divider()
                            SessionPropertyRow(key: "Branch", value: metadata.branch)
                            Divider()
                        }
                        SessionPropertyRow(key: "Working directory", value: session.cwd)
                        if session.createdAt != .distantPast {
                            Divider()
                            SessionPropertyRow(
                                key: "Started",
                                value: session.createdAt.formatted(date: .abbreviated, time: .standard)
                            )
                        }
                        Divider()
                        SessionPropertyRow(key: "Session key", value: session.sessionID, monospaced: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox("Tags") {
                    SessionTagEditor(session: session, repository: repository)
                        .padding(.top, 4)
                }

                GroupBox("Activity") {
                    SessionActivityView(session: session)
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

private struct SessionPropertyRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
