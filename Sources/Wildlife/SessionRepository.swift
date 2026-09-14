import AppKit
import Combine
import Foundation
import WildlifeCore

@MainActor
final class SessionRepository: ObservableObject {
    private let diskStore: SessionDiskStore
    @Published private(set) var sessions: [SessionRecord] = []
    @Published var selectedSessionKey: String?
    @Published var searchText = ""

    init(inMemory: Bool = false) throws {
        if inMemory {
            diskStore = SessionDiskStore(url: nil)
        } else {
            try RuntimePaths.prepareDirectories()
            let url = RuntimePaths.applicationSupportDirectory.appendingPathComponent("Sessions.json")
            diskStore = SessionDiskStore(url: url)
        }
        sessions = try diskStore.load()
    }

    var selectedSession: SessionRecord? {
        guard let selectedSessionKey else { return nil }
        return sessions.first { $0.stableKey == selectedSessionKey }
    }

    var activeSessions: [SessionRecord] {
        sessions.filter { $0.workflow == .inProgress }.sorted {
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
                ($0.runtimeStatus.priority, -$0.updatedAt.timeIntervalSince1970) <
                ($1.runtimeStatus.priority, -$1.updatedAt.timeIntervalSince1970)
            }
        case .backlog:
            return filtered.sorted { $0.backlogOrder < $1.backlogOrder }
        case .completed:
            return filtered.sorted { ($0.endedAt ?? $0.updatedAt) > ($1.endedAt ?? $1.updatedAt) }
        }
    }

    private var filteredSessions: [SessionRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            [$0.displayTitle, $0.cwd, $0.provider.displayName, $0.sessionID, $0.notesMarkdown]
                .contains { $0.lowercased().contains(query) }
        }
    }

    func consume(_ event: BridgeEvent) {
        defer { removeSpoolFile(eventID: event.eventID) }
        let key = "\(event.provider.rawValue):\(event.sessionID)"
        let session: SessionRecord
        if let existing = sessions.first(where: { $0.stableKey == key }) {
            session = existing
        } else {
            guard event.tty != nil else { return }
            session = SessionRecord(
                provider: event.provider,
                sessionID: event.sessionID,
                sourceTitle: "",
                emoji: EmojiAllocator.next(used: Set(sessions.map(\.emoji))),
                cwd: event.cwd,
                createdAt: event.timestamp,
                updatedAt: event.timestamp,
                workflow: .inProgress,
                runtimeStatus: .starting
            )
            sessions.append(session)
        }
        guard SessionEventReducer.apply(event, to: session) else { return }
        persist()
        objectWillChange.send()
    }

    func importSessions(_ imported: [ImportedSession]) -> Int {
        var count = 0
        var keys = Set(sessions.map(\.stableKey))
        var usedEmoji = Set(sessions.map(\.emoji))
        var metadataChanged = false
        for item in imported {
            if let existing = sessions.first(where: { $0.stableKey == item.stableKey }) {
                if existing.sourceTitle.isEmpty && !item.title.isEmpty {
                    existing.sourceTitle = item.title
                    metadataChanged = true
                }
                continue
            }
            let emoji = EmojiAllocator.next(used: usedEmoji)
            usedEmoji.insert(emoji)
            let record = SessionRecord(
                provider: item.provider,
                sessionID: item.sessionID,
                sourceTitle: item.title,
                emoji: emoji,
                cwd: item.cwd,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                workflow: .completed,
                runtimeStatus: .ended
            )
            record.endedAt = item.updatedAt
            sessions.append(record)
            keys.insert(item.stableKey)
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
        let ordered = sessions(in: .backlog).filter { $0.stableKey != session.stableKey }
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

    func delete(_ session: SessionRecord) {
        if selectedSessionKey == session.stableKey { selectedSessionKey = nil }
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

    func reconcileProcesses(now: Date = Date(), gracePeriod: TimeInterval = 15) {
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
                    session.workflow = .completed
                    session.runtimeStatus = .ended
                    session.endedAt = now
                    session.updatedAt = now
                    session.activeSubagentCount = 0
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
        try? diskStore.save(sessions)
    }

    private func removeSpoolFile(eventID: String) {
        let url = RuntimePaths.inboxDirectory.appendingPathComponent("\(eventID).json")
        try? FileManager.default.removeItem(at: url)
    }
}
