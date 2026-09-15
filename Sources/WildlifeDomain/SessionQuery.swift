import Foundation

package enum SessionBuiltInView: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case attention
    case favorites
    case recent
    case archived

    package var id: String { "builtin:\(rawValue)" }
    package var displayName: String { rawValue.capitalized }
}

package struct SessionFilter: Codable, Equatable, Sendable {
    package var query: String
    package var providers: Set<AgentProvider>
    package var workflows: Set<WorkflowBucket>
    package var projectKeys: Set<String>
    package var tags: Set<String>
    package var recentDays: Int?
    package var pinnedOnly: Bool
    package var attentionOnly: Bool
    package var includeArchived: Bool
    package var archivedOnly: Bool

    package init(
        query: String = "",
        providers: Set<AgentProvider> = [],
        workflows: Set<WorkflowBucket> = [],
        projectKeys: Set<String> = [],
        tags: Set<String> = [],
        recentDays: Int? = nil,
        pinnedOnly: Bool = false,
        attentionOnly: Bool = false,
        includeArchived: Bool = false,
        archivedOnly: Bool = false
    ) {
        self.query = query
        self.providers = providers
        self.workflows = workflows
        self.projectKeys = projectKeys
        self.tags = tags
        self.recentDays = recentDays
        self.pinnedOnly = pinnedOnly
        self.attentionOnly = attentionOnly
        self.includeArchived = includeArchived
        self.archivedOnly = archivedOnly
    }

    package static func builtIn(_ view: SessionBuiltInView) -> SessionFilter {
        switch view {
        case .all: SessionFilter()
        case .attention: SessionFilter(attentionOnly: true)
        case .favorites: SessionFilter(pinnedOnly: true)
        case .recent: SessionFilter(recentDays: 7)
        case .archived: SessionFilter(includeArchived: true, archivedOnly: true)
        }
    }

    package func matches(_ session: Session, now: Date) -> Bool {
        if archivedOnly {
            guard session.archivedAt != nil else { return false }
        } else if !includeArchived, session.archivedAt != nil {
            return false
        }
        if pinnedOnly, !session.isPinned { return false }
        if attentionOnly, session.attentionReason(at: now) == nil { return false }
        if !providers.isEmpty, !providers.contains(session.provider) { return false }
        if !workflows.isEmpty, !workflows.contains(session.workflow) { return false }
        if !projectKeys.isEmpty, !projectKeys.contains(session.projectKey) { return false }
        if let recentDays, session.updatedAt < now.addingTimeInterval(-Double(recentDays) * 86_400) {
            return false
        }
        if !tags.isEmpty, tags.isDisjoint(with: Set(session.tags)) { return false }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = [
            session.displayTitle,
            session.cwd,
            session.provider.displayName,
            session.sessionID,
            session.notes,
            session.project?.branch ?? "",
        ] + session.tags
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}

package struct SavedSessionView: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package var name: String
    package var filter: SessionFilter

    package init(id: String = UUID().uuidString, name: String, filter: SessionFilter) {
        self.id = id
        self.name = name
        self.filter = filter
    }
}

package struct OrganizationRules: Codable, Equatable, Sendable {
    package var autoArchiveAfterDays: Int?
    package var backlogFailedSessions: Bool
    package var backlogInterruptedSessions: Bool

    package init(
        autoArchiveAfterDays: Int? = nil,
        backlogFailedSessions: Bool = false,
        backlogInterruptedSessions: Bool = false
    ) {
        self.autoArchiveAfterDays = autoArchiveAfterDays
        self.backlogFailedSessions = backlogFailedSessions
        self.backlogInterruptedSessions = backlogInterruptedSessions
    }
}

package struct SessionQueryResult: Equatable, Sendable {
    package let sessions: [Session]
    package let conflictingWorktrees: Set<String>
    package let tags: [String]
    package let projects: [(key: String, name: String)]

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessions == rhs.sessions
            && lhs.conflictingWorktrees == rhs.conflictingWorktrees
            && lhs.tags == rhs.tags
            && lhs.projects.elementsEqual(rhs.projects, by: ==)
    }
}

package enum SessionQuery {
    package static let defaultHistoryDays = 7

    package static func run(
        sessions: some Sequence<Session>,
        filter: SessionFilter,
        searchText: String,
        includeOlder: Bool,
        now: Date = Date()
    ) -> SessionQueryResult {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allSessions = Array(sessions)
        let historyCutoff = now.addingTimeInterval(-Double(defaultHistoryDays) * 86_400)
        let scoped = allSessions.filter { session in
            (includeOlder || session.workflow == .inProgress || session.updatedAt >= historyCutoff)
                && filter.matches(session, now: now)
                && (search.isEmpty || SessionFilter(query: search, includeArchived: true).matches(session, now: now))
        }
        let sorted = scoped.sorted(by: sessionComesBefore)
        let active = allSessions.filter { $0.workflow == .inProgress && $0.archivedAt == nil }
        let conflicts = conflictingWorktrees(in: active)
        let tags = TagNormalizer.normalizeAll(allSessions.flatMap(\.tags))
        let pairs = allSessions.map { ($0.projectKey, $0.projectDisplayName) }
        let projects = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            .map { (key: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return SessionQueryResult(sessions: sorted, conflictingWorktrees: conflicts, tags: tags, projects: projects)
    }

    package static func activeSessions(in sessions: some Sequence<Session>) -> [Session] {
        sessions.filter { $0.workflow == .inProgress && $0.archivedAt == nil }.sorted(by: sessionComesBefore)
    }

    package static func conflictingWorktrees(in sessions: some Sequence<Session>) -> Set<String> {
        let grouped = Dictionary(grouping: sessions.filter { $0.workflow == .inProgress }) {
            $0.project?.worktreeRoot ?? ""
        }
        return Set(grouped.compactMap { key, records in !key.isEmpty && records.count > 1 ? key : nil })
    }

    private static func sessionComesBefore(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.workflow != rhs.workflow {
            return WorkflowBucket.allCases.firstIndex(of: lhs.workflow)! < WorkflowBucket.allCases.firstIndex(of: rhs.workflow)!
        }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        switch lhs.workflow {
        case .inProgress:
            let leftPriority = lhs.activeStatus?.priority ?? Int.max
            let rightPriority = rhs.activeStatus?.priority ?? Int.max
            return (leftPriority, -lhs.updatedAt.timeIntervalSince1970) < (rightPriority, -rhs.updatedAt.timeIntervalSince1970)
        case .backlog:
            return (lhs.lifecycle.backlogOrder ?? Int.max) < (rhs.lifecycle.backlogOrder ?? Int.max)
        case .completed:
            return (lhs.endedAt ?? lhs.updatedAt) > (rhs.endedAt ?? rhs.updatedAt)
        }
    }
}

package enum TagNormalizer {
    package static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    package static func normalizeAll(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = normalize(value)
            return !normalized.isEmpty && seen.insert(normalized).inserted ? normalized : nil
        }.sorted()
    }
}
