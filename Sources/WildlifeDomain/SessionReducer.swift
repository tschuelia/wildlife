import Foundation

package enum ProcessLiveness: Equatable, Sendable {
    case matching
    case notRunning
    case identityMismatch
    case unknown
}

package struct SessionCollection: Equatable, Sendable {
    package var sessions: [SessionID: Session]
    package var tombstones: Set<SessionID>

    package init(sessions: [Session] = [], tombstones: Set<SessionID> = []) {
        self.sessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        self.tombstones = tombstones
    }

    package var values: [Session] { Array(sessions.values) }

    package subscript(id: SessionID) -> Session? {
        get { sessions[id] }
        set { sessions[id] = newValue }
    }

    @discardableResult
    package mutating func consume(
        _ event: AgentEvent,
        rules: OrganizationRules = OrganizationRules()
    ) -> SessionTransition? {
        guard event.isValid else { return nil }
        let wasDeleted = tombstones.contains(event.sessionID)
        var session: Session
        if let existing = sessions[event.sessionID] {
            session = existing
        } else {
            guard event.process?.tty != nil else { return nil }
            session = Session(
                id: event.sessionID,
                sourceTitle: "",
                emoji: .automatic(EmojiAllocator.next(used: reservedEmojis(at: event.timestamp))),
                cwd: event.cwd,
                createdAt: event.timestamp,
                updatedAt: event.timestamp,
                lifecycle: .active(ActiveSessionState(status: .starting))
            )
        }

        let previousStatus = session.activeStatus
        guard SessionReducer.reduce(event, into: &session) else { return nil }
        session.attentionSnoozedUntil = nil
        if session.archivedAt != nil, event.kind != .sessionEnd { session.archivedAt = nil }
        if session.workflow == .inProgress, case .historical = session.emoji {
            session.emoji = .automatic(EmojiAllocator.next(used: reservedEmojis(at: event.timestamp)))
        }
        if session.workflow == .completed, shouldMoveToBacklog(session, rules: rules) {
            moveToBacklog(&session, order: nextBacklogOrder())
        }
        sessions[session.id] = session
        if event.kind == .sessionStart { finishSuperseded(by: event) }
        if wasDeleted { tombstones.remove(event.sessionID) }
        return SessionTransition(
            sessionID: session.id,
            event: event,
            previousStatus: previousStatus,
            currentStatus: session.activeStatus
        )
    }

    @discardableResult
    package mutating func importSessions(_ imported: [ImportedSession]) -> Int {
        var inserted = 0
        for item in imported where !tombstones.contains(item.id) {
            if var existing = sessions[item.id] {
                var changed = false
                if existing.sourceTitle.isEmpty, !item.title.isEmpty {
                    existing.sourceTitle = item.title
                    changed = true
                }
                if existing.createdAt == .distantPast {
                    existing.createdAt = item.createdAt
                    changed = true
                }
                if changed { sessions[item.id] = existing }
                continue
            }
            sessions[item.id] = Session(
                id: item.id,
                sourceTitle: item.title,
                emoji: .historical,
                cwd: item.cwd,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                lifecycle: .completed(EndedSessionState(endedAt: item.updatedAt))
            )
            inserted += 1
        }
        return inserted
    }

    package mutating func update(_ id: SessionID, _ edit: (inout Session) throws -> Void) rethrows {
        guard var session = sessions[id] else { return }
        try edit(&session)
        sessions[id] = session
    }

    package mutating func move(_ id: SessionID, to bucket: WorkflowBucket, now: Date = Date()) {
        guard var session = sessions[id], session.workflow != .inProgress, bucket != .inProgress else { return }
        let ended = EndedSessionState(endedAt: session.endedAt ?? now)
        session.lifecycle = bucket == .backlog
            ? .backlog(ended, order: nextBacklogOrder())
            : .completed(ended)
        session.updatedAt = now
        sessions[id] = session
    }

    package mutating func reorderBacklog(_ orderedIDs: [SessionID]) {
        var seen = Set<SessionID>()
        let existing = values.filter { $0.workflow == .backlog }
            .sorted { ($0.lifecycle.backlogOrder ?? .max) < ($1.lifecycle.backlogOrder ?? .max) }
        let valid = Set(existing.map(\.id))
        let final = orderedIDs.filter { valid.contains($0) && seen.insert($0).inserted }
            + existing.map(\.id).filter { seen.insert($0).inserted }
        for (order, id) in final.enumerated() {
            guard var session = sessions[id], let endedAt = session.endedAt else { continue }
            session.lifecycle = .backlog(EndedSessionState(endedAt: endedAt), order: order)
            sessions[id] = session
        }
    }

    package mutating func delete(_ id: SessionID) {
        sessions.removeValue(forKey: id)
        tombstones.insert(id)
    }

    package mutating func clearExpiredSnoozes(now: Date) {
        for id in sessions.keys {
            guard var session = sessions[id], session.attentionSnoozedUntil.map({ $0 <= now }) == true else { continue }
            session.attentionSnoozedUntil = nil
            sessions[id] = session
        }
    }

    package mutating func applyAutomaticArchive(rules: OrganizationRules, now: Date) {
        guard let days = rules.autoArchiveAfterDays, days > 0 else { return }
        for id in sessions.keys {
            guard var session = sessions[id],
                  session.workflow == .completed,
                  session.archivedAt == nil,
                  !session.isPinned,
                  now.timeIntervalSince(session.endedAt ?? session.updatedAt) >= Double(days) * 86_400 else { continue }
            session.archivedAt = now
            sessions[id] = session
        }
    }

    package mutating func releaseOldAutomaticEmojis(now: Date) {
        for id in sessions.keys {
            guard var session = sessions[id], shouldReleaseEmoji(session, now: now) else { continue }
            session.emoji = .historical
            sessions[id] = session
        }
    }

    package mutating func reconcileProcesses(
        now: Date,
        gracePeriod: TimeInterval = 15,
        rules: OrganizationRules,
        liveness: (AgentProcessIdentity) -> ProcessLiveness
    ) {
        for id in sessions.keys {
            guard var session = sessions[id],
                  case .active(var active) = session.lifecycle,
                  let process = session.process else { continue }
            switch liveness(process) {
            case .matching:
                active.processMissingSince = nil
                session.lifecycle = .active(active)
            case .notRunning, .identityMismatch:
                if let missing = active.processMissingSince, now.timeIntervalSince(missing) >= gracePeriod {
                    finish(&session, at: now, reason: "process_ended")
                    if shouldMoveToBacklog(session, rules: rules) {
                        moveToBacklog(&session, order: nextBacklogOrder())
                    }
                } else if active.processMissingSince == nil {
                    active.processMissingSince = now
                    session.lifecycle = .active(active)
                }
            case .unknown:
                active.processMissingSince = nil
                session.lifecycle = .active(active)
            }
            sessions[id] = session
        }
    }

    package mutating func reconcileActiveDuplicates(now: Date) {
        let active = values.filter { $0.workflow == .inProgress && $0.process != nil }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        var retained: [(AgentProvider, AgentProcessIdentity)] = []
        for candidate in active {
            guard let process = candidate.process else { continue }
            if candidate.isForked {
                continue
            }
            if retained.contains(where: { $0.0 == candidate.provider && sharesIdentity($0.1, process) }) {
                guard var session = sessions[candidate.id] else { continue }
                finish(&session, at: max(now, session.lastEventAt), reason: "session_replaced")
                sessions[candidate.id] = session
            } else {
                retained.append((candidate.provider, process))
            }
        }
    }

    private mutating func finishSuperseded(by event: AgentEvent) {
        guard event.startSource != "fork", event.startSource != "compact" else { return }
        for id in sessions.keys where id != event.sessionID {
            guard var session = sessions[id], session.workflow == .inProgress,
                  session.provider == event.sessionID.provider,
                  session.lastEventAt <= event.timestamp,
                  sharesIdentity(session.process, event.process) else { continue }
            finish(&session, at: event.timestamp, reason: event.startSource ?? "session_replaced")
            sessions[id] = session
        }
    }

    private func reservedEmojis(at now: Date) -> Set<String> {
        Set(values.compactMap { session in
            guard !shouldReleaseEmoji(session, now: now) else { return nil }
            if case .historical = session.emoji { return nil }
            return session.emoji.value
        })
    }

    private func shouldReleaseEmoji(_ session: Session, now: Date) -> Bool {
        guard session.workflow == .completed, case .automatic = session.emoji else { return false }
        guard let endedAt = session.endedAt else { return true }
        return now.timeIntervalSince(endedAt) >= 3_600
    }

    private func nextBacklogOrder() -> Int {
        (values.compactMap(\.lifecycle.backlogOrder).max() ?? -1) + 1
    }

    private func shouldMoveToBacklog(_ session: Session, rules: OrganizationRules) -> Bool {
        switch session.lastTurnOutcome {
        case .failed: rules.backlogFailedSessions
        case .interrupted: rules.backlogInterruptedSessions
        default: false
        }
    }

    private func sharesIdentity(_ lhs: AgentProcessIdentity?, _ rhs: AgentProcessIdentity?) -> Bool {
        guard let lhs, let rhs, lhs.pid == rhs.pid else { return false }
        if !lhs.startIdentity.isEmpty, !rhs.startIdentity.isEmpty { return lhs.startIdentity == rhs.startIdentity }
        guard let leftTTY = lhs.tty, !leftTTY.isEmpty, let rightTTY = rhs.tty, !rightTTY.isEmpty else { return true }
        return leftTTY == rightTTY
    }

    private func moveToBacklog(_ session: inout Session, order: Int) {
        let ended = EndedSessionState(endedAt: session.endedAt ?? session.updatedAt)
        session.lifecycle = .backlog(ended, order: order)
    }

    private func finish(_ session: inout Session, at timestamp: Date, reason: String) {
        let event = AgentEvent(
            sessionID: session.id,
            kind: .sessionEnd,
            timestamp: max(timestamp, session.lastEventAt),
            cwd: session.cwd,
            endReason: reason
        )
        _ = SessionReducer.reduce(event, into: &session)
    }
}

package enum SessionReducer {
    @discardableResult
    package static func reduce(_ event: AgentEvent, into session: inout Session) -> Bool {
        guard event.schema == AgentEvent.schemaVersion,
              event.sessionID == session.id,
              event.id != session.lastEventID,
              !session.activities.contains(where: { $0.id == event.id }),
              event.timestamp >= session.lastEventAt else { return false }

        let previousStatus = session.activeStatus
        let previousWorkflow = session.workflow
        let previousEventAt = session.lastEventAt
        let wasInactive = session.workflow != .inProgress
        session.lastEventID = event.id
        session.lastEventAt = event.timestamp
        session.updatedAt = event.timestamp
        if !event.cwd.isEmpty { session.cwd = event.cwd }
        if let process = event.process { session.process = process }
        if let model = event.model { session.modelName = model }

        switch event.kind {
        case .sessionStart:
            if session.createdAt == .distantPast { session.createdAt = event.timestamp }
            if event.startSource == "fork" { session.isForked = true }
            if event.startSource == "resume", wasInactive { session.resumeCount += 1 }
            session.lifecycle = .active(ActiveSessionState(status: .waitingForInput))
        case .userPromptSubmit:
            setActive(.processing, session: &session)
            session.toolName = nil
        case .preToolUse:
            setActive(.runningTool, session: &session)
            session.toolName = event.toolName
        case .permissionRequest:
            setActive(.waitingForApproval, session: &session)
            session.toolName = event.toolName
        case .postToolUse, .postToolUseFailure, .permissionDenied, .postCompact:
            setActive(.processing, session: &session)
            session.toolName = event.toolName
        case .preCompact:
            setActive(.compacting, session: &session)
            session.toolName = nil
        case .subagentStart:
            session.activeSubagentCount += 1
            setActive(.processing, session: &session)
        case .subagentStop:
            session.activeSubagentCount = max(0, session.activeSubagentCount - 1)
            setActive(.processing, session: &session)
        case .stop, .interrupt:
            setActive(.waitingForInput, session: &session)
            session.toolName = nil
        case .notification:
            if event.notificationType == "idle_prompt" { setActive(.waitingForInput, session: &session) }
        case .stopFailure:
            setActive(.error, session: &session)
            session.toolName = nil
        case .sessionEnd:
            session.lifecycle = .completed(EndedSessionState(endedAt: event.timestamp))
            session.activeSubagentCount = 0
            session.toolName = nil
        }
        SessionActivityRecorder.record(
            event,
            previousStatus: previousStatus,
            previousWorkflow: previousWorkflow,
            previousEventAt: previousEventAt,
            in: &session
        )
        return true
    }

    private static func setActive(_ status: ActiveStatus, session: inout Session) {
        session.lifecycle = .active(ActiveSessionState(status: status))
    }
}

package enum SessionActivityRecorder {
    package static let detailLimit = 500

    fileprivate static func record(
        _ event: AgentEvent,
        previousStatus: ActiveStatus?,
        previousWorkflow: WorkflowBucket,
        previousEventAt: Date,
        in session: inout Session
    ) {
        if previousWorkflow == .inProgress, let previousStatus {
            addDuration(max(0, event.timestamp.timeIntervalSince(previousEventAt)), status: previousStatus, to: &session.activitySummary)
        }
        switch event.kind {
        case .preToolUse: session.activitySummary.toolCount += 1
        case .permissionRequest: session.activitySummary.permissionCount += 1
        case .preCompact: session.activitySummary.compactionCount += 1
        case .interrupt: session.activitySummary.interruptionCount += 1
        case .postToolUseFailure, .stopFailure: session.activitySummary.failureCount += 1
        case .subagentStart: session.activitySummary.subagentCount += 1
        default: break
        }
        session.activities.append(SessionActivity(
            id: event.id,
            timestamp: event.timestamp,
            event: event.kind,
            status: session.activeStatus.map(ActivityStatus.init) ?? .ended,
            toolName: event.toolName,
            endReason: event.endReason,
            notificationType: event.notificationType,
            subagentCount: session.activeSubagentCount
        ))
        if session.activities.count > detailLimit {
            session.activities.removeFirst(session.activities.count - detailLimit)
        }
        switch event.kind {
        case .sessionStart, .userPromptSubmit: session.lastTurnOutcome = nil
        case .interrupt: session.lastTurnOutcome = .interrupted
        case .postToolUseFailure, .stopFailure: session.lastTurnOutcome = .failed
        case .stop: session.lastTurnOutcome = .completed
        default: break
        }
    }

    private static func addDuration(_ duration: TimeInterval, status: ActiveStatus, to summary: inout SessionActivitySummary) {
        switch status {
        case .starting, .processing, .runningTool, .compacting: summary.activeDuration += duration
        case .waitingForInput: summary.waitingForInputDuration += duration
        case .waitingForApproval: summary.waitingForApprovalDuration += duration
        case .error: break
        }
    }
}
