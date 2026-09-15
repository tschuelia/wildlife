import Foundation
import Observation
import WildlifeDomain
import WildlifeInfrastructure

@MainActor
@Observable
final class SessionLibrary {
    private let database: SessionDatabase
    private(set) var collection = SessionCollection()
    private(set) var savedViews: [SavedSessionView] = []
    private(set) var isLoaded = false
    private(set) var errorMessage: String?

    var selectedSessionID: SessionID?
    var selectedViewID = SessionBuiltInView.all.id
    var searchText = ""
    var activeFilter = SessionFilter()
    var includesOlderSessions = false

    init(database: SessionDatabase) {
        self.database = database
    }

    var sessions: [Session] { collection.values }
    var selectedSession: Session? { selectedSessionID.flatMap { collection[$0] } }
    var activeSessions: [Session] { SessionQuery.activeSessions(in: sessions) }

    var queryResult: SessionQueryResult {
        SessionQuery.run(
            sessions: sessions,
            filter: activeFilter,
            searchText: searchText,
            includeOlder: includesOlderSessions
        )
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            let stored = try await database.load()
            collection = stored.collection
            savedViews = stored.savedViews
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryLoad() async {
        isLoaded = false
        await load()
    }

    func session(_ id: SessionID) -> Session? { collection[id] }

    @discardableResult
    func consume(_ event: AgentEvent, rules: OrganizationRules) async -> SessionTransition? {
        guard let persisted = await commit({ state -> SessionTransition? in
            state.consume(event, rules: rules)
        }) else { return nil }
        return persisted
    }

    @discardableResult
    func importSessions(_ sessions: [ImportedSession]) async -> Int? {
        await commit { $0.importSessions(sessions) }
    }

    func updateProject(_ project: ProjectMetadata?, sessionID: SessionID) async {
        await commit { state in
            state.update(sessionID) { session in
                guard session.project != project else { return }
                session.project = project
            }
        }
    }

    func updateTitle(_ value: String, sessionID: SessionID) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        await update(sessionID) { session in
            session.customTitle = trimmed.isEmpty ? nil : trimmed
            session.updatedAt = Date()
        }
    }

    func updateEmoji(_ value: String, sessionID: SessionID) async -> String? {
        guard EmojiAllocator.isSingleEmoji(value) else { return "Choose exactly one emoji." }
        await update(sessionID) { $0.emoji = .custom(value) }
        return nil
    }

    func updateTags(_ values: [String], sessionID: SessionID) async {
        await update(sessionID) { $0.tags = TagNormalizer.normalizeAll(values) }
    }

    func updateNotes(_ value: String, sessionID: SessionID) async {
        await update(sessionID) { $0.notes = value }
    }

    func togglePinned(_ id: SessionID) async {
        await update(id) { $0.isPinned.toggle() }
    }

    func setArchived(_ archived: Bool, sessionID: SessionID) async {
        let persisted: Void? = await commit { state in
            state.update(sessionID) { session in
                guard session.workflow != .inProgress else { return }
                session.archivedAt = archived ? Date() : nil
            }
        }
        if persisted != nil, archived, selectedSessionID == sessionID { selectedSessionID = nil }
    }

    func snooze(_ id: SessionID, until: Date?) async {
        await update(id) { $0.attentionSnoozedUntil = until }
    }

    func move(_ id: SessionID, to bucket: WorkflowBucket) async {
        await commit { $0.move(id, to: bucket) }
    }

    func reorderBacklog(_ ids: [SessionID]) async {
        await commit { $0.reorderBacklog(ids) }
    }

    func delete(_ id: SessionID) async {
        let persisted: Void? = await commit { $0.delete(id) }
        if persisted != nil, selectedSessionID == id { selectedSessionID = nil }
    }

    func runMaintenance(rules: OrganizationRules, liveness: (AgentProcessIdentity) -> ProcessLiveness) async {
        await commit { state in
            let now = Date()
            state.clearExpiredSnoozes(now: now)
            state.reconcileActiveDuplicates(now: now)
            state.reconcileProcesses(now: now, rules: rules, liveness: liveness)
            state.releaseOldAutomaticEmojis(now: now)
            state.applyAutomaticArchive(rules: rules, now: now)
        }
    }

    func showOlderSessions() { includesOlderSessions = true }

    func applyView(_ id: String) {
        selectedViewID = id
        searchText = ""
        if let builtIn = SessionBuiltInView.allCases.first(where: { $0.id == id }) {
            activeFilter = .builtIn(builtIn)
        } else if let raw = id.removingPrefix("workflow:"), let workflow = WorkflowBucket(rawValue: raw) {
            activeFilter = SessionFilter(workflows: [workflow])
        } else {
            activeFilter = savedViews.first(where: { $0.id == id })?.filter ?? .builtIn(.all)
        }
    }

    func markFilterAsCustom() {
        selectedViewID = "custom"
    }

    func saveView(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var filter = activeFilter
        if !searchText.isEmpty { filter.query = searchText }
        let view = SavedSessionView(name: trimmed, filter: filter)
        var next = savedViews
        next.append(view)
        if await persistViews(next) { applyView(view.id) }
    }

    func deleteSelectedView() async {
        let next = savedViews.filter { $0.id != selectedViewID }
        guard next.count != savedViews.count else { return }
        if await persistViews(next) { applyView(SessionBuiltInView.all.id) }
    }

    func selectAdjacent(offset: Int) {
        let visible = queryResult.sessions
        guard !visible.isEmpty else { return }
        let current = selectedSessionID.flatMap { id in visible.firstIndex { $0.id == id } }
        let base = current ?? (offset > 0 ? -1 : visible.count)
        selectedSessionID = visible[min(max(0, base + offset), visible.count - 1)].id
    }

    func clearError() { errorMessage = nil }

    private func update(_ id: SessionID, edit: @escaping (inout Session) -> Void) async {
        await commit { $0.update(id, edit) }
    }

    @discardableResult
    private func commit<T>(_ mutation: (inout SessionCollection) -> T) async -> T? {
        let previous = collection
        var next = previous
        let result = mutation(&next)
        guard next != previous else { return result }
        do {
            try await database.apply(previous: previous, next: next)
            collection = next
            errorMessage = nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    private func persistViews(_ views: [SavedSessionView]) async -> Bool {
        do {
            try await database.saveViews(views)
            savedViews = views
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
