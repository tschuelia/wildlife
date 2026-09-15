import SwiftUI
import WildlifeCore

struct SessionViewToolbar: View {
    private static let draftID = "draft"

    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @State private var showingSaveView = false
    @State private var viewName = ""

    var body: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $settings.selectedSessionViewID) {
                ForEach(SessionBuiltInView.allCases) { view in
                    Text(view.displayName).tag(view.id)
                }
                if settings.selectedSessionViewID == Self.draftID {
                    Text("Custom").tag(Self.draftID)
                }
                ForEach(settings.savedSessionViews) { view in
                    Text(view.name).tag(view.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 150)
            .onChange(of: settings.selectedSessionViewID) { _, _ in applySelectedView() }

            filterMenu

            Button {
                viewName = ""
                showingSaveView = true
            } label: {
                Image(systemName: "bookmark.badge.plus")
            }
            .help("Save current filters")

            if settings.savedSessionViews.contains(where: { $0.id == settings.selectedSessionViewID }) {
                Button(role: .destructive) {
                    settings.deleteView(id: settings.selectedSessionViewID)
                    applySelectedView()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete saved view")
            }
        }
        .onAppear { applySelectedView() }
        .alert("Save Current View", isPresented: $showingSaveView) {
            TextField("View name", text: $viewName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveCurrentView() }
                .disabled(viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The current search and filter choices will be saved locally.")
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("Provider") {
                ForEach(AgentProvider.allCases) { provider in
                    Toggle(provider.displayName, isOn: arrayToggle(\.providerRaws, value: provider.rawValue))
                }
            }
            Section("Workflow") {
                ForEach(WorkflowBucket.allCases) { workflow in
                    Toggle(workflow.displayName, isOn: arrayToggle(\.workflowRaws, value: workflow.rawValue))
                }
            }
            Section("Focus") {
                Toggle("Favorites only", isOn: filterToggle(\.pinnedOnly))
                Toggle("Attention only", isOn: filterToggle(\.attentionOnly))
                Toggle("Include archived", isOn: filterToggle(\.includeArchived))
                Picker("Updated", selection: recentDaysBinding) {
                    Text("Any time").tag(0)
                    Text("Today").tag(1)
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                }
            }
            if !repository.allTags.isEmpty {
                Menu("Tags") {
                    ForEach(repository.allTags, id: \.self) { tag in
                        Toggle(tag, isOn: arrayToggle(\.tags, value: tag))
                    }
                }
            }
            if !repository.projectChoices.isEmpty {
                Menu("Projects") {
                    ForEach(repository.projectChoices, id: \.key) { project in
                        Toggle(project.name, isOn: arrayToggle(\.projectKeys, value: project.key))
                    }
                }
            }
            Divider()
            Button("Clear Filters") {
                settings.selectedSessionViewID = SessionBuiltInView.all.id
                repository.activeFilter = .builtIn(.all)
                repository.searchText = ""
            }
        } label: {
            Label("Filters", systemImage: hasCustomFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var hasCustomFilter: Bool {
        repository.activeFilter != .builtIn(.all) || !repository.searchText.isEmpty
    }

    private var recentDaysBinding: Binding<Int> {
        Binding(
            get: { repository.activeFilter.recentDays ?? 0 },
            set: { value in updateFilter { $0.recentDays = value > 0 ? value : nil } }
        )
    }

    private func filterToggle(_ keyPath: WritableKeyPath<SessionFilter, Bool>) -> Binding<Bool> {
        Binding(
            get: { repository.activeFilter[keyPath: keyPath] },
            set: { value in updateFilter { $0[keyPath: keyPath] = value } }
        )
    }

    private func arrayToggle(
        _ keyPath: WritableKeyPath<SessionFilter, [String]>,
        value: String
    ) -> Binding<Bool> {
        Binding(
            get: { repository.activeFilter[keyPath: keyPath].contains(value) },
            set: { enabled in
                updateFilter { filter in
                    var values = filter[keyPath: keyPath]
                    if enabled {
                        if !values.contains(value) { values.append(value) }
                    } else {
                        values.removeAll { $0 == value }
                    }
                    filter[keyPath: keyPath] = values.sorted()
                }
            }
        )
    }

    private func updateFilter(_ update: (inout SessionFilter) -> Void) {
        var filter = repository.activeFilter
        update(&filter)
        repository.activeFilter = filter
        settings.selectedSessionViewID = Self.draftID
    }

    private func applySelectedView() {
        repository.activeFilter = settings.filter(for: settings.selectedSessionViewID)
        repository.searchText = ""
    }

    private func saveCurrentView() {
        var filter = repository.activeFilter
        filter.query = repository.searchText
        guard let view = settings.saveView(name: viewName, filter: filter) else { return }
        repository.activeFilter = view.filter
        repository.searchText = ""
    }
}

struct SessionTagEditor: View {
    let session: SessionRecord
    @ObservedObject var repository: SessionRepository
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Comma-separated tags", text: $draft)
                    .onSubmit { commit() }
                Button("Apply") { commit() }
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(suggestions, id: \.self) { tag in
                            Button(tag) {
                                repository.updateTags(session.tags + [tag], for: session)
                                syncDraft()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear { syncDraft() }
        .onChange(of: session.tags) { _, _ in syncDraft() }
    }

    private var suggestions: [String] {
        repository.allTags.filter { !session.tags.contains($0) }
    }

    private func commit() {
        repository.updateTags(draft.split(separator: ",").map { String($0) }, for: session)
        syncDraft()
    }

    private func syncDraft() {
        draft = session.tags.joined(separator: ", ")
    }
}

struct SessionActivityView: View {
    let session: SessionRecord

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(at: context.date)
        }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), alignment: .leading)], alignment: .leading, spacing: 10) {
                metric("Elapsed", duration: elapsed(at: now))
                metric("Active", duration: session.activitySummary.activeDuration + currentDuration(at: now, statuses: [.starting, .processing, .runningTool, .compacting]))
                metric("Waiting", duration: session.activitySummary.waitingForInputDuration + currentDuration(at: now, statuses: [.waitingForInput]))
                metric("Approval", duration: session.activitySummary.waitingForApprovalDuration + currentDuration(at: now, statuses: [.waitingForApproval]))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), alignment: .leading)], alignment: .leading, spacing: 7) {
                count("Tools", session.activitySummary.toolCount)
                count("Permissions", session.activitySummary.permissionCount)
                count("Compactions", session.activitySummary.compactionCount)
                count("Interruptions", session.activitySummary.interruptionCount)
                count("Failures", session.activitySummary.failureCount)
                count("Subagents", session.activitySummary.subagentCount)
            }
            Divider()
            if session.activities.isEmpty {
                Text("Detailed activity becomes available when new live events arrive.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.activities.reversed()) { activity in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(for: activity.eventName))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: activity))
                                Text(activity.timestamp, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(activity.status.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func elapsed(at now: Date) -> TimeInterval {
        (session.endedAt ?? now).timeIntervalSince(session.createdAt)
    }

    private func currentDuration(at now: Date, statuses: Set<RuntimeStatus>) -> TimeInterval {
        guard session.workflow == .inProgress, statuses.contains(session.runtimeStatus) else { return 0 }
        return max(0, now.timeIntervalSince(session.lastEventAt))
    }

    private func metric(_ title: String, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(durationText(duration))
                .font(.callout.monospacedDigit())
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private func count(_ title: String, _ value: Int) -> some View {
        Text("\(title) \(value)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    private func label(for activity: SessionActivity) -> String {
        if let tool = activity.toolName, !tool.isEmpty { return "\(activity.eventName): \(tool)" }
        return activity.eventName.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    private func icon(for event: String) -> String {
        switch event {
        case "PermissionRequest": "hand.raised"
        case "PreToolUse", "PostToolUse", "PostToolUseFailure": "hammer"
        case "PreCompact", "PostCompact": "arrow.down.right.and.arrow.up.left"
        case "SubagentStart", "SubagentStop": "person.2"
        case "SessionEnd", "ProcessEnded": "stop.circle"
        case "StopFailure": "exclamationmark.triangle"
        default: "circle.fill"
        }
    }
}

struct SessionCommands: Commands {
    @ObservedObject private var repository: SessionRepository
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var actions: SessionActionController

    init(repository: SessionRepository, settings: AppSettings, actions: SessionActionController) {
        _repository = ObservedObject(wrappedValue: repository)
        _settings = ObservedObject(wrappedValue: settings)
        _actions = ObservedObject(wrappedValue: actions)
    }

    var body: some Commands {
        CommandMenu("Sessions") {
            ForEach(Array(SessionBuiltInView.allCases.enumerated()), id: \.element.id) { index, view in
                Button(view.displayName) { select(view) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button("Previous Session") { repository.selectAdjacentSession(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Session") { repository.selectAdjacentSession(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Focus or Resume Selected") { primaryAction() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(repository.selectedSession == nil)
            Button(repository.selectedSession?.isPinned == true ? "Unpin Selected" : "Pin Selected") {
                if let session = repository.selectedSession { repository.togglePinned(session) }
            }
            .keyboardShortcut("p", modifiers: .command)
            Button(repository.selectedSession?.archivedAt == nil ? "Archive Selected" : "Restore Selected") {
                if let session = repository.selectedSession {
                    repository.setArchived(session.archivedAt == nil, for: session)
                }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(repository.selectedSession?.workflow == .inProgress || repository.selectedSession == nil)
        }
    }

    private func select(_ view: SessionBuiltInView) {
        settings.selectedSessionViewID = view.id
        repository.activeFilter = .builtIn(view)
        repository.searchText = ""
    }

    private func primaryAction() {
        guard let session = repository.selectedSession else { return }
        if session.workflow == .inProgress { _ = actions.focus(session) }
        else { actions.requestResume(session) }
    }
}
