import SwiftUI
import WildlifeDomain

struct SessionListView: View {
    @Bindable var library: SessionLibrary
    @Bindable var preferences: PreferencesStore
    let coordinator: AppCoordinator
    let actions: SessionActionController
    @State private var pendingDeletion: Session?

    var body: some View {
        Group {
            if !library.isLoaded {
                ProgressView("Opening Wildlife…")
            } else if library.queryResult.sessions.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "leaf",
                    description: Text(emptyDescription)
                )
            } else {
                sessionList
            }
        }
        .safeAreaInset(edge: .bottom) {
            historyFooter
        }
        .confirmationDialog(
            "Remove this Wildlife record?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { session in
            Button("Remove Record", role: .destructive) {
                Task { await library.delete(session.id) }
            }
        } message: { _ in
            Text("The Codex or Claude session and transcript remain untouched.")
        }
    }

    private var sessionList: some View {
        List(selection: $library.selectedSessionID) {
            if let workflow = singleWorkflow, preferences.value.groupByProject {
                ForEach(projectGroups, id: \.key) { group in
                    Section(group.name) {
                        rows(group.sessions, reorderGroup: workflow == .backlog && canReorderBacklog ? group : nil)
                    }
                }
            } else if singleWorkflow != nil {
                Section(singleWorkflow?.displayName ?? "Sessions") {
                    rows(library.queryResult.sessions, reorderGroup: ungroupedBacklogGroup)
                }
            } else {
                ForEach(WorkflowBucket.allCases) { workflow in
                    let sessions = library.queryResult.sessions.filter { $0.workflow == workflow }
                    if !sessions.isEmpty {
                        Section(workflow.displayName) { rows(sessions, reorderGroup: nil) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .top) {
            if !library.queryResult.conflictingWorktrees.isEmpty {
                Label(
                    "Multiple active sessions share a worktree",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func rows(_ sessions: [Session], reorderGroup: ProjectGroup?) -> some View {
        ForEach(sessions) { session in
            SessionRow(
                session: session,
                hasWorktreeConflict: session.project.map {
                    library.queryResult.conflictingWorktrees.contains($0.worktreeRoot)
                } ?? false
            )
            .tag(session.id)
            .simultaneousGesture(
                TapGesture(count: 1).onEnded {
                    library.selectedSessionID = session.id
                }
            )
            .contextMenu {
                SessionActionItems(
                    session: session,
                    library: library,
                    coordinator: coordinator,
                    actions: actions,
                    requestDeletion: { pendingDeletion = session }
                )
            }
            .moveDisabled(reorderGroup == nil)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    library.selectedSessionID = session.id
                    if session.workflow == .inProgress { _ = actions.focus(session) }
                    else { actions.requestResume(session) }
                }
            )
        }
        .onMove { source, destination in
            guard let reorderGroup else { return }
            reorder(reorderGroup, source: source, destination: destination)
        }
    }

    private func reorder(_ group: ProjectGroup, source: IndexSet, destination: Int) {
        var moved = group.sessions.map(\.id)
        moved.move(fromOffsets: source, toOffset: destination)
        if group.key == "*" {
            Task { await library.reorderBacklog(moved) }
            return
        }
        let allBacklog = library.sessions.filter { $0.workflow == .backlog && $0.archivedAt == nil }
            .sorted { ($0.lifecycle.backlogOrder ?? .max) < ($1.lifecycle.backlogOrder ?? .max) }
        var final = allBacklog.map(\.id)
        let groupPositions = final.indices.filter { index in
            library.session(final[index])?.projectKey == group.key
        }
        for (position, id) in zip(groupPositions, moved) { final[position] = id }
        Task { await library.reorderBacklog(final) }
    }

    private var singleWorkflow: WorkflowBucket? {
        library.activeFilter.workflows.count == 1 ? library.activeFilter.workflows.first : nil
    }

    private var projectGroups: [ProjectGroup] {
        Dictionary(grouping: library.queryResult.sessions, by: \.projectKey)
            .map { key, sessions in
                ProjectGroup(key: key, name: sessions.first?.projectDisplayName ?? "Unknown Project", sessions: sessions)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var ungroupedBacklogGroup: ProjectGroup? {
        guard canReorderBacklog else { return nil }
        return ProjectGroup(key: "*", name: "Backlog", sessions: library.queryResult.sessions)
    }

    @ViewBuilder
    private var historyFooter: some View {
        if !library.includesOlderSessions {
            HStack {
                Text("Showing active sessions and the last 7 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Load older sessions") {
                    Task { await coordinator.importOlderHistory() }
                }
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var emptyTitle: String { library.searchText.isEmpty ? "No sessions in this view" : "No matching sessions" }
    private var emptyDescription: String { "Adjust the filters or start a Codex or Claude session." }
}

private struct ProjectGroup {
    let key: String
    let name: String
    let sessions: [Session]
}

private struct SessionRow: View {
    let session: Session
    let hasWorktreeConflict: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(session.emoji.value).font(.title2).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.displayTitle).font(.headline).lineLimit(1)
                    if session.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                HStack(spacing: 8) {
                    Label(session.provider.displayName, systemImage: session.provider == .codex ? "terminal" : "sparkles")
                    Label(session.projectDisplayName, systemImage: "folder")
                    if let branch = session.project?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                    if hasWorktreeConflict {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !session.tags.isEmpty {
                    Text(session.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    StatusIndicator(status: session.activeStatus)
                    Text(session.activeStatus?.displayName ?? session.workflow.displayName)
                }
                .font(.caption)
                Text(session.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private extension SessionListView {
    var canReorderBacklog: Bool {
        library.activeFilter == SessionFilter(workflows: [.backlog]) && library.searchText.isEmpty
    }
}
