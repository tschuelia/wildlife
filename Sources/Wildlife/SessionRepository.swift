import AppKit
import Combine
import Foundation
import WildlifeCore

@MainActor
final class SessionRepository: ObservableObject {
    private let diskStore: SessionDiskStore
    private var deletedSessionKeys: Set<String> = []
    @Published private(set) var sessions: [SessionRecord] = []
    @Published var selectedSessionKey: String?
    @Published var searchText = ""
    @Published var activeFilter = SessionFilter()
    @Published private(set) var includesOlderSessions = false

    init(inMemory: Bool = false) throws {
        if inMemory {
            diskStore = SessionDiskStore(url: nil)
        } else {
            try RuntimePaths.prepareDirectories()
            let url = RuntimePaths.applicationSupportDirectory.appendingPathComponent("Sessions.json")
            diskStore = SessionDiskStore(url: url)
        }
        let state = try diskStore.loadState()
        sessions = state.sessions
        deletedSessionKeys = Set(state.deletedSessionKeys)
        let reconciled = SessionSupersession.reconcilePersistedActiveSessions(in: sessions)
        let dead = SessionSupersession.finishDefinitivelyDeadSessions(
            in: sessions,
            liveness: ProcessInspector.liveness
        )
        let released = SessionHistoryPolicy.releaseOldAutomaticEmojis(in: sessions)
        if reconciled > 0 || dead > 0 || released > 0 { persist() }
    }

    var selectedSession: SessionRecord? {
        guard let selectedSessionKey else { return nil }
        return sessions.first { $0.stableKey == selectedSessionKey }
    }

    var activeSessions: [SessionRecord] {
        sessions.filter { $0.workflow == .inProgress && $0.archivedAt == nil }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.runtimeStatus.priority != $1.runtimeStatus.priority {
                return $0.runtimeStatus.priority < $1.runtimeStatus.priority
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func sessions(in bucket: WorkflowBucket) -> [SessionRecord] {
        let filtered = filteredSessions.filter { $0.workflow == bucket }
        switch bucket {
        case .inProgress:
            return filtered.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return ($0.runtimeStatus.priority, -$0.updatedAt.timeIntervalSince1970) <
                ($1.runtimeStatus.priority, -$1.updatedAt.timeIntervalSince1970)
            }
        case .backlog:
            return filtered.sorted { $0.backlogOrder < $1.backlogOrder }
        case .completed:
            return filtered.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return ($0.endedAt ?? $0.updatedAt) > ($1.endedAt ?? $1.updatedAt)
            }
        }
    }

    private var filteredSessions: [SessionRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return historyScopedSessions.filter { session in
            guard activeFilter.matches(session) else { return false }
            guard !query.isEmpty else { return true }
            let values = [
                session.displayTitle, session.cwd, session.provider.displayName,
                session.sessionID, session.notesMarkdown, session.projectMetadata?.branch ?? "",
            ] + session.tags
            return values.contains { $0.lowercased().contains(query) }
        }
    }

    private var historyScopedSessions: [SessionRecord] {
        guard !includesOlderSessions else { return sessions }
        let now = Date()
        return sessions.filter { SessionHistoryPolicy.isVisibleByDefault($0, now: now) }
    }

    func showOlderSessions() {
        includesOlderSessions = true
    }

    @discardableResult
    func consume(
        _ event: BridgeEvent,
        rules: OrganizationRules = OrganizationRules()
    ) -> SessionTransition? {
        guard event.isValidForTransport else { return nil }
        let key = event.stableKey
        let restoresDeletedSession = deletedSessionKeys.contains(key)
        let session: SessionRecord
        if let existing = sessions.first(where: { $0.stableKey == key }) {
            session = existing
        } else {
            guard event.tty != nil else { return nil }
            session = SessionRecord(
                provider: event.provider,
                sessionID: event.sessionID,
                sourceTitle: "",
                emoji: EmojiAllocator.next(
                    used: SessionHistoryPolicy.reservedEmojis(in: sessions, now: event.timestamp)
                ),
                cwd: event.cwd,
                createdAt: event.timestamp,
                updatedAt: event.timestamp,
                workflow: .inProgress,
                runtimeStatus: .starting
            )
            sessions.append(session)
        }
        let previousStatus = session.runtimeStatus
        let previousWorkflow = session.workflow
        let previousEventAt = session.lastEventAt
        guard SessionEventReducer.apply(event, to: session) else { return nil }
        _ = SessionSupersession.finishSessionsSuperseded(by: event, in: sessions)
        if session.workflow == .inProgress,
           session.emoji == SessionHistoryPolicy.historicalEmoji {
            session.emoji = EmojiAllocator.next(
                used: SessionHistoryPolicy.reservedEmojis(in: sessions, now: event.timestamp)
            )
            session.emojiWasCustomized = false
        }
        SessionActivityRecorder.record(
            event,
            previousStatus: previousStatus,
            previousWorkflow: previousWorkflow,
            previousEventAt: previousEventAt,
            in: session
        )
        session.attentionSnoozedUntil = nil
        if session.archivedAt != nil, event.lifecycleEvent != "SessionEnd" {
            session.archivedAt = nil
        }
        if session.workflow == .completed, SessionOrganization.shouldMoveToBacklog(session, rules: rules) {
            session.workflow = .backlog
            session.backlogOrder = nextBacklogOrder()
        }
        if restoresDeletedSession {
            deletedSessionKeys.remove(key)
        }
        persist()
        objectWillChange.send()
        return SessionTransition(
            sessionKey: key,
            event: event,
            previousStatus: previousStatus,
            currentStatus: session.runtimeStatus
        )
    }

    func importSessions(_ imported: [ImportedSession]) -> Int {
        var count = 0
        var metadataChanged = false
        for item in imported where !deletedSessionKeys.contains(item.stableKey) {
            if let existing = sessions.first(where: { $0.stableKey == item.stableKey }) {
                if existing.sourceTitle.isEmpty && !item.title.isEmpty {
                    existing.sourceTitle = item.title
                    metadataChanged = true
                }
                if existing.createdAt == .distantPast {
                    existing.createdAt = item.createdAt
                    metadataChanged = true
                }
                if existing.workflow == .completed, existing.endedAt == nil {
                    existing.endedAt = item.updatedAt
                    metadataChanged = true
                }
                continue
            }
            let record = SessionRecord(
                provider: item.provider,
                sessionID: item.sessionID,
                sourceTitle: item.title,
                emoji: SessionHistoryPolicy.historicalEmoji,
                cwd: item.cwd,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                workflow: .completed,
                runtimeStatus: .ended
            )
            record.endedAt = item.updatedAt
            sessions.append(record)
            count += 1
        }
        if count > 0 || metadataChanged {
            persist()
            objectWillChange.send()
        }
        return count
    }

    func move(_ session: SessionRecord, to bucket: WorkflowBucket) {
        guard session.workflow != .inProgress, bucket != .inProgress else { return }
        session.workflow = bucket
        if bucket == .backlog {
            let largest = sessions.filter { $0.workflow == .backlog }.map(\.backlogOrder).max() ?? 0
            session.backlogOrder = largest + 1
        }
        session.updatedAt = Date()
        persist()
        objectWillChange.send()
    }

    func reorderBacklog(_ session: SessionRecord, before target: SessionRecord?) {
        guard session.workflow == .backlog else { return }
        let ordered = sessions
            .filter { $0.workflow == .backlog && $0.stableKey != session.stableKey }
            .sorted { $0.backlogOrder < $1.backlogOrder }
        var newOrder = ordered
        let index = target.flatMap { target in newOrder.firstIndex { $0.stableKey == target.stableKey } } ?? newOrder.endIndex
        newOrder.insert(session, at: index)
        for (offset, item) in newOrder.enumerated() { item.backlogOrder = Double(offset) }
        persist()
        objectWillChange.send()
    }

    func updateCustomEmoji(_ emoji: String, for session: SessionRecord) -> String? {
        guard EmojiAllocator.isSingleEmoji(emoji) else { return "Choose exactly one emoji." }
        guard !sessions.contains(where: { $0 !== session && $0.emoji == emoji }) else {
            return "That emoji is already assigned to another session."
        }
        session.emoji = emoji
        session.emojiWasCustomized = true
        persist()
        objectWillChange.send()
        return nil
    }

    func updateCustomTitle(_ title: String, for session: SessionRecord) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedTitle = trimmed.isEmpty ? nil : trimmed
        guard session.customTitle != updatedTitle else { return }
        session.customTitle = updatedTitle
        session.updatedAt = Date()
        persist()
        objectWillChange.send()
    }

    @discardableResult
    func commitDrop(
        sessionKey: String,
        to bucket: WorkflowBucket,
        backlogOrder proposedOrder: [String]? = nil
    ) -> Bool {
        guard bucket != .inProgress,
              let session = sessions.first(where: { $0.stableKey == sessionKey }),
              session.workflow != .inProgress else { return false }

        var changed = session.workflow != bucket
        session.workflow = bucket

        if bucket == .backlog {
            let currentBacklog = sessions
                .filter { $0.workflow == .backlog }
                .sorted { $0.backlogOrder < $1.backlogOrder }
            let validKeys = Set(currentBacklog.map(\.stableKey))
            var seen = Set<String>()
            var finalKeys = (proposedOrder ?? currentBacklog.map(\.stableKey)).filter {
                validKeys.contains($0) && seen.insert($0).inserted
            }
            finalKeys.append(contentsOf: currentBacklog.map(\.stableKey).filter { seen.insert($0).inserted })

            let byKey = Dictionary(uniqueKeysWithValues: currentBacklog.map { ($0.stableKey, $0) })
            for (index, key) in finalKeys.enumerated() {
                guard let item = byKey[key] else { continue }
                let order = Double(index)
                if item.backlogOrder != order {
                    item.backlogOrder = order
                    changed = true
                }
            }
        }

        guard changed else { return false }
        session.updatedAt = Date()
        persist()
        objectWillChange.send()
        return true
    }

    func save() {
        persist()
        objectWillChange.send()
    }

    func session(forKey key: String) -> SessionRecord? {
        sessions.first { $0.stableKey == key }
    }

    func updateProjectMetadata(_ metadata: ProjectMetadata?, forSessionKey key: String) {
        guard let session = session(forKey: key), session.projectMetadata != metadata else { return }
        session.projectMetadata = metadata
        persist()
        objectWillChange.send()
    }

    func updateTags(_ tags: [String], for session: SessionRecord) {
        let normalized = TagNormalizer.normalizeAll(tags)
        guard session.tags != normalized else { return }
        session.tags = normalized
        persist()
        objectWillChange.send()
    }

    func togglePinned(_ session: SessionRecord) {
        session.isPinned.toggle()
        persist()
        objectWillChange.send()
    }

    func setArchived(_ archived: Bool, for session: SessionRecord, now: Date = Date()) {
        guard session.workflow != .inProgress else { return }
        guard (session.archivedAt != nil) != archived else { return }
        let value = archived ? now : nil
        session.archivedAt = value
        if archived, selectedSessionKey == session.stableKey { selectedSessionKey = nil }
        persist()
        objectWillChange.send()
    }

    func snooze(_ session: SessionRecord, until date: Date?) {
        session.attentionSnoozedUntil = date
        persist()
        objectWillChange.send()
    }

    func clearExpiredSnoozes(now: Date = Date()) {
        var changed = false
        for session in sessions where session.attentionSnoozedUntil.map({ $0 <= now }) == true {
            session.attentionSnoozedUntil = nil
            changed = true
        }
        if changed {
            persist()
            objectWillChange.send()
        }
    }

    func selectAdjacentSession(offset: Int) {
        let visible = WorkflowBucket.allCases.flatMap { sessions(in: $0) }
        guard !visible.isEmpty else { return }
        let current = selectedSessionKey.flatMap { key in
            visible.firstIndex { $0.stableKey == key }
        }
        let base = current ?? (offset > 0 ? -1 : visible.count)
        let index = min(max(0, base + offset), visible.count - 1)
        selectedSessionKey = visible[index].stableKey
    }

    func applyAutomaticArchive(rules: OrganizationRules, now: Date = Date()) {
        var changed = false
        for session in sessions where SessionOrganization.shouldAutoArchive(session, rules: rules, now: now) {
            session.archivedAt = now
            if selectedSessionKey == session.stableKey { selectedSessionKey = nil }
            changed = true
        }
        if changed {
            persist()
            objectWillChange.send()
        }
    }

    func releaseOldAutomaticEmojis(now: Date = Date()) {
        guard SessionHistoryPolicy.releaseOldAutomaticEmojis(in: sessions, now: now) > 0 else { return }
        persist()
        objectWillChange.send()
    }

    var allTags: [String] {
        TagNormalizer.normalizeAll(historyScopedSessions.flatMap(\.tags))
    }

    var projectChoices: [(key: String, name: String)] {
        let pairs = historyScopedSessions.map { ($0.projectKey, $0.projectDisplayName) }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            .map { (key: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func delete(_ session: SessionRecord) {
        if selectedSessionKey == session.stableKey { selectedSessionKey = nil }
        deletedSessionKeys.insert(session.stableKey)
        sessions.removeAll { $0.stableKey == session.stableKey }
        persist()
    }

    func copyKey(_ session: SessionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.sessionID, forType: .string)
    }

    func copyResumeCommand(_ session: SessionRecord, settings: AppSettings) throws {
        let command = try ResumeCommandTemplate.render(
            settings.template(for: session.provider),
            sessionID: session.sessionID,
            cwd: session.cwd
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func reconcileProcesses(
        now: Date = Date(),
        gracePeriod: TimeInterval = 15,
        rules: OrganizationRules = OrganizationRules()
    ) {
        var changed = false
        for session in sessions where session.workflow == .inProgress {
            guard let pid = session.processID else { continue }
            if ProcessInspector.isAlive(pid: pid, startIdentity: session.processStartIdentity) {
                if session.processMissingSince != nil {
                    session.processMissingSince = nil
                    changed = true
                }
            } else if let missing = session.processMissingSince {
                if now.timeIntervalSince(missing) >= gracePeriod {
                    SessionActivityRecorder.recordProcessEnd(at: now, in: session)
                    session.workflow = .completed
                    session.runtimeStatus = .ended
                    session.endedAt = now
                    session.updatedAt = now
                    session.activeSubagentCount = 0
                    if SessionOrganization.shouldMoveToBacklog(session, rules: rules) {
                        session.workflow = .backlog
                        session.backlogOrder = nextBacklogOrder()
                    }
                    changed = true
                }
            } else {
                session.processMissingSince = now
                changed = true
            }
        }
        if changed {
            persist()
            objectWillChange.send()
        }
    }

    private func persist() {
        try? diskStore.save(PersistedSessions(
            sessions: sessions,
            deletedSessionKeys: deletedSessionKeys.sorted()
        ))
    }

    private func nextBacklogOrder() -> Double {
        (sessions.filter { $0.workflow == .backlog }.map(\.backlogOrder).max() ?? 0) + 1
    }
}
