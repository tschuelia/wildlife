import Foundation

package enum SessionSupersession {
    @discardableResult
    package static func finishSessionsSuperseded(
        by event: BridgeEvent,
        in sessions: [SessionRecord]
    ) -> Int {
        guard event.lifecycleEvent == "SessionStart",
              event.startSource != "fork",
              event.startSource != "compact" else { return 0 }

        var count = 0
        for session in sessions where session.workflow == .inProgress
            && session.stableKey != event.stableKey
            && session.provider == event.provider
            && session.lastEventAt <= event.timestamp
            && sharesAgentIdentity(session, event) {
            if finish(session, at: event.timestamp, reason: event.startSource ?? "session_replaced") {
                count += 1
            }
        }
        return count
    }

    @discardableResult
    package static func finishDefinitivelyDeadSessions(
        in sessions: [SessionRecord],
        liveness: (Int32, String?) -> ProcessLiveness
    ) -> Int {
        var count = 0
        for session in sessions where session.workflow == .inProgress {
            guard let pid = session.processID else { continue }
            switch liveness(pid, session.processStartIdentity) {
            case .notRunning, .identityMismatch:
                // The process could have exited at any point while Wildlife was
                // closed. Keep its last known event time so a stale record does
                // not become recent merely because the app was reopened.
                if finish(session, at: session.lastEventAt, reason: "process_ended") {
                    count += 1
                }
            case .matching, .unknown:
                continue
            }
        }
        return count
    }

    @discardableResult
    package static func reconcilePersistedActiveSessions(in sessions: [SessionRecord]) -> Int {
        let active = sessions
            .filter { $0.workflow == .inProgress }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        var retained: [SessionRecord] = []
        var count = 0

        for session in active {
            if session.isForkedSession {
                retained.append(session)
                continue
            }
            guard let replacement = retained.first(where: {
                !$0.isForkedSession
                    && $0.provider == session.provider
                    && sharesAgentIdentity($0, session)
            }) else {
                retained.append(session)
                continue
            }
            let timestamp = max(session.lastEventAt, replacement.createdAt)
            if finish(session, at: timestamp, reason: "session_replaced") {
                count += 1
            }
        }
        return count
    }

    private static func sharesAgentIdentity(_ session: SessionRecord, _ event: BridgeEvent) -> Bool {
        if let sessionPID = session.processID, let eventPID = event.processID {
            guard sessionPID == eventPID else { return false }
            if let sessionStart = nonempty(session.processStartIdentity),
               let eventStart = nonempty(event.processStartIdentity) {
                return sessionStart == eventStart
            }
            return true
        }
        guard let sessionTTY = nonempty(session.tty), let eventTTY = nonempty(event.tty) else { return false }
        return sessionTTY == eventTTY
    }

    private static func sharesAgentIdentity(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if let lhsPID = lhs.processID, let rhsPID = rhs.processID {
            guard lhsPID == rhsPID else { return false }
            if let lhsStart = nonempty(lhs.processStartIdentity),
               let rhsStart = nonempty(rhs.processStartIdentity) {
                return lhsStart == rhsStart
            }
            return true
        }
        guard let lhsTTY = nonempty(lhs.tty), let rhsTTY = nonempty(rhs.tty) else { return false }
        return lhsTTY == rhsTTY
    }

    private static func finish(_ session: SessionRecord, at timestamp: Date, reason: String) -> Bool {
        let event = BridgeEvent(
            provider: session.provider,
            sessionID: session.sessionID,
            lifecycleEvent: "SessionEnd",
            timestamp: max(timestamp, session.lastEventAt),
            cwd: session.cwd,
            endReason: reason
        )
        let previousStatus = session.runtimeStatus
        let previousWorkflow = session.workflow
        let previousEventAt = session.lastEventAt
        guard SessionEventReducer.apply(event, to: session) else { return false }
        SessionActivityRecorder.record(
            event,
            previousStatus: previousStatus,
            previousWorkflow: previousWorkflow,
            previousEventAt: previousEventAt,
            in: session
        )
        return true
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
