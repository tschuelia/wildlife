import SwiftUI
import WildlifeDomain

struct SessionInspector: View {
    let session: Session
    @Bindable var library: SessionLibrary
    let coordinator: AppCoordinator
    let actions: SessionActionController
    @State private var tab = InspectorTab.overview
    @State private var title = ""
    @State private var tagDraft = ""
    @State private var notes = ""
    @State private var emojiError: String?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Detail", selection: $tab) {
                ForEach(InspectorTab.allCases) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            Group {
                switch tab {
                case .overview: overview
                case .activity: activity
                case .notes: notesEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: session.id) { synchronizeDrafts() }
        .onChange(of: session.customTitle) { _, _ in title = session.customTitle ?? session.displayTitle }
        .onChange(of: session.notes) { _, value in if notes != value { notes = value } }
        .confirmationDialog("Remove this Wildlife record?", isPresented: $confirmingDelete) {
            Button("Remove Record", role: .destructive) { Task { await library.delete(session.id) } }
        } message: {
            Text("The Codex or Claude session and transcript remain untouched.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        NativeEmojiPickerButton(emoji: session.emoji.value) { value in
                            Task { emojiError = await library.updateEmoji(value, sessionID: session.id) }
                        }
                            .frame(width: 52, height: 52)
                        TextField("Session title", text: $title)
                            .font(.title2.bold())
                            .textFieldStyle(.plain)
                            .onSubmit { Task { await library.updateTitle(title, sessionID: session.id) } }
                    }
                    if let emojiError { Text(emojiError).font(.caption).foregroundStyle(.red) }
                    Label(
                        session.provider.displayName,
                        systemImage: session.provider == .codex ? "terminal" : "sparkles"
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                SessionActionMenu(
                    session: session,
                    library: library,
                    coordinator: coordinator,
                    actions: actions,
                    requestDeletion: { confirmingDelete = true }
                )
            }
            HStack {
                Button {
                    if session.workflow == .inProgress { _ = actions.focus(session) }
                    else { actions.requestResume(session) }
                } label: {
                    Label(
                        session.workflow == .inProgress ? "Focus Terminal" : "Resume Session",
                        systemImage: session.workflow == .inProgress ? "scope" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                StatusIndicator(status: session.activeStatus)
                Text(session.activeStatus?.displayName ?? session.workflow.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Project") {
                    VStack(alignment: .leading, spacing: 0) {
                        PropertyRow(label: "Repository", value: session.project?.repositoryRoot ?? session.cwd)
                        if let project = session.project {
                            Divider()
                            PropertyRow(label: "Worktree", value: project.worktreeRoot)
                            Divider()
                            PropertyRow(label: "Branch", value: project.branch)
                        }
                    }
                }
                GroupBox("Session") {
                    VStack(alignment: .leading, spacing: 0) {
                        PropertyRow(label: "Session ID", value: session.sessionID, monospaced: true)
                        Divider()
                        PropertyRow(label: "Working directory", value: session.cwd)
                        Divider()
                        PropertyRow(label: "Started", value: session.createdAt.formatted(date: .abbreviated, time: .standard))
                        if let model = session.modelName {
                            Divider()
                            PropertyRow(label: "Model", value: model)
                        }
                    }
                }
                GroupBox("Tags") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Comma-separated tags", text: $tagDraft)
                            .onSubmit { applyTags() }
                        if !session.tags.isEmpty {
                            Text(session.tags.map { "#\($0)" }.joined(separator: "  "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    private var activity: some View {
        SessionActivityView(session: session)
    }

    private var notesEditor: some View {
        TextEditor(text: $notes)
            .font(.body)
            .padding(.horizontal, 14)
            .task(id: notes) {
                guard notes != session.notes else { return }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                await library.updateNotes(notes, sessionID: session.id)
            }
    }

    private func synchronizeDrafts() {
        title = session.customTitle ?? session.displayTitle
        emojiError = nil
        tagDraft = session.tags.joined(separator: ", ")
        notes = session.notes
    }

    private func applyTags() {
        Task {
            await library.updateTags(tagDraft.split(separator: ",").map(String.init), sessionID: session.id)
        }
    }
}

private enum InspectorTab: String, CaseIterable, Identifiable {
    case overview
    case activity
    case notes

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

private struct PropertyRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct SessionActivityView: View {
    let session: Session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], spacing: 12) {
                        metric("Elapsed", elapsed(at: context.date))
                        metric("Active", session.activitySummary.activeDuration + currentDuration(at: context.date, statuses: [.starting, .processing, .runningTool, .compacting]))
                        metric("Waiting", session.activitySummary.waitingForInputDuration + currentDuration(at: context.date, statuses: [.waitingForInput]))
                        metric("Approval", session.activitySummary.waitingForApprovalDuration + currentDuration(at: context.date, statuses: [.waitingForApproval]))
                    }
                    counts
                    Divider()
                    if session.activities.isEmpty {
                        ContentUnavailableView("No detailed activity", systemImage: "clock")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.activities.reversed()) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: icon(item.event)).frame(width: 18).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(label(item))
                                        Text(item.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.status.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
    }

    private var counts: some View {
        let summary = session.activitySummary
        return Text("Tools \(summary.toolCount)  ·  Permissions \(summary.permissionCount)  ·  Compactions \(summary.compactionCount)  ·  Interruptions \(summary.interruptionCount)  ·  Failures \(summary.failureCount)  ·  Subagents \(summary.subagentCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func elapsed(at now: Date) -> TimeInterval { (session.endedAt ?? now).timeIntervalSince(session.createdAt) }

    private func currentDuration(at now: Date, statuses: Set<ActiveStatus>) -> TimeInterval {
        guard let status = session.activeStatus, statuses.contains(status) else { return 0 }
        return max(0, now.timeIntervalSince(session.lastEventAt))
    }

    private func metric(_ title: String, _ duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(durationText(duration)).font(.callout.monospacedDigit())
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private func label(_ item: SessionActivity) -> String {
        guard let tool = item.toolName, !tool.isEmpty else { return item.event.rawValue }
        return "\(item.event.rawValue): \(tool)"
    }

    private func icon(_ event: AgentEvent.Kind) -> String {
        switch event {
        case .permissionRequest: "hand.raised"
        case .preToolUse, .postToolUse, .postToolUseFailure: "hammer"
        case .preCompact, .postCompact: "arrow.down.right.and.arrow.up.left"
        case .subagentStart, .subagentStop: "person.2"
        case .sessionEnd: "stop.circle"
        case .stopFailure: "exclamationmark.triangle"
        default: "circle.fill"
        }
    }
}
