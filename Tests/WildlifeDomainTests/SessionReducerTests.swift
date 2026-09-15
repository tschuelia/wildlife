import Foundation
import Testing
@testable import WildlifeDomain

@Suite("Session lifecycle")
struct SessionReducerTests {
    private let base = Date(timeIntervalSince1970: 1_000)
    private let process = AgentProcessIdentity(pid: 42, startIdentity: "start", tty: "/dev/ttys001")

    @Test("Events drive lifecycle, activity, and attention")
    func lifecycleAndActivity() {
        let id = SessionID(provider: .claude, externalID: "session")
        var collection = SessionCollection()

        #expect(collection.consume(event(id, .sessionStart, at: 0)) != nil)
        #expect(collection[id]?.activeStatus == .waitingForInput)
        #expect(collection.consume(event(id, .userPromptSubmit, at: 2)) != nil)
        #expect(collection.consume(event(id, .preToolUse, at: 5, tool: "Read")) != nil)
        #expect(collection.consume(event(id, .permissionRequest, at: 8, tool: "Write")) != nil)

        let waiting = collection[id]
        #expect(waiting?.activeStatus == .waitingForApproval)
        #expect(waiting?.toolName == "Write")
        #expect(waiting?.activitySummary.activeDuration == 6)
        #expect(waiting?.activitySummary.waitingForInputDuration == 2)
        #expect(waiting?.activitySummary.toolCount == 1)
        #expect(waiting?.activitySummary.permissionCount == 1)
        #expect(waiting?.attentionReason(at: base.addingTimeInterval(9)) == .approval)

        #expect(collection.consume(event(id, .stopFailure, at: 10)) != nil)
        #expect(collection[id]?.activeStatus == .error)
        #expect(collection[id]?.activitySummary.waitingForApprovalDuration == 2)
        #expect(collection[id]?.activitySummary.failureCount == 1)
        #expect(collection.consume(event(id, .sessionEnd, at: 12)) != nil)
        #expect(collection[id]?.workflow == .completed)
        #expect(collection[id]?.endedAt == base.addingTimeInterval(12))
        #expect(collection[id]?.activities.last?.status == .ended)
    }

    @Test("Duplicate, out-of-order, and foreign events are rejected")
    func rejection() {
        let id = SessionID(provider: .codex, externalID: "one")
        let other = SessionID(provider: .codex, externalID: "other")
        var session = activeSession(id: id, at: 5)
        let accepted = event(id, .preToolUse, at: 7, tool: "Read")
        #expect(SessionReducer.reduce(accepted, into: &session))
        let next = event(id, .postToolUse, at: 7, tool: "Read")
        #expect(SessionReducer.reduce(next, into: &session))
        let snapshot = session
        #expect(!SessionReducer.reduce(accepted, into: &session))
        #expect(!SessionReducer.reduce(event(id, .stop, at: 6), into: &session))
        #expect(!SessionReducer.reduce(event(other, .stop, at: 8), into: &session))
        #expect(session == snapshot)
    }

    @Test("A normal start supersedes only the same provider process")
    func supersession() {
        let oldID = SessionID(provider: .codex, externalID: "old")
        let newestID = SessionID(provider: .codex, externalID: "new")
        let claudeID = SessionID(provider: .claude, externalID: "claude")
        var collection = SessionCollection(sessions: [
            activeSession(id: oldID, at: 0),
            activeSession(id: claudeID, at: 0),
        ])

        #expect(collection.consume(event(newestID, .sessionStart, at: 10, source: "clear")) != nil)
        #expect(collection[oldID]?.workflow == .completed)
        #expect(collection[oldID]?.activities.last?.endReason == "clear")
        #expect(collection[newestID]?.workflow == .inProgress)
        #expect(collection[claudeID]?.workflow == .inProgress)

        let forkID = SessionID(provider: .codex, externalID: "fork")
        #expect(collection.consume(event(forkID, .sessionStart, at: 11, source: "fork")) != nil)
        #expect(collection[newestID]?.workflow == .inProgress)
        #expect(collection[forkID]?.isForked == true)
    }

    @Test("Persisted duplicate reconciliation keeps the newest identity")
    func duplicateReconciliation() {
        let staleID = SessionID(provider: .codex, externalID: "stale")
        let latestID = SessionID(provider: .codex, externalID: "latest")
        let reusedID = SessionID(provider: .codex, externalID: "reused")
        let otherProvider = SessionID(provider: .claude, externalID: "other")
        var stale = activeSession(id: staleID, at: 1)
        var latest = activeSession(id: latestID, at: 2)
        var reused = activeSession(id: reusedID, at: 0)
        reused.process = AgentProcessIdentity(pid: 42, startIdentity: "another-start", tty: process.tty)
        var claude = activeSession(id: otherProvider, at: 0)
        var fork = activeSession(id: SessionID(provider: .codex, externalID: "fork"), at: 0)
        fork.isForked = true
        claude.process = process
        stale.process = process
        latest.process = process
        var collection = SessionCollection(sessions: [stale, latest, reused, claude, fork])

        collection.reconcileActiveDuplicates(now: base.addingTimeInterval(3))

        #expect(collection[staleID]?.workflow == .completed)
        #expect(collection[latestID]?.workflow == .inProgress)
        #expect(collection[reusedID]?.workflow == .inProgress)
        #expect(collection[otherProvider]?.workflow == .inProgress)
        #expect(collection[fork.id]?.workflow == .inProgress)
    }

    @Test("Process reconciliation requires a continuous failed grace period")
    func processGracePeriod() {
        let id = SessionID(provider: .codex, externalID: "process")
        var collection = SessionCollection(sessions: [activeSession(id: id, at: 0)])
        let rules = OrganizationRules()

        collection.reconcileProcesses(now: base, gracePeriod: 10, rules: rules) { _ in .notRunning }
        #expect(collection[id]?.workflow == .inProgress)
        collection.reconcileProcesses(now: base.addingTimeInterval(20), gracePeriod: 10, rules: rules) { _ in .unknown }
        #expect(collection[id]?.lifecycle.activeState?.processMissingSince == nil)
        collection.reconcileProcesses(now: base.addingTimeInterval(21), gracePeriod: 10, rules: rules) { _ in .notRunning }
        #expect(collection[id]?.workflow == .inProgress)
        collection.reconcileProcesses(now: base.addingTimeInterval(32), gracePeriod: 10, rules: rules) { _ in .notRunning }
        #expect(collection[id]?.workflow == .completed)
        #expect(collection[id]?.activities.last?.endReason == "process_ended")
    }

    @Test("History, deletion tombstones, resume, and backlog automation compose")
    func historyAndAutomation() {
        let id = SessionID(provider: .claude, externalID: "history")
        let imported = ImportedSession(
            provider: .claude,
            sessionID: id.externalID,
            title: "Imported",
            cwd: "/tmp/project",
            createdAt: base,
            updatedAt: base.addingTimeInterval(1)
        )
        var collection = SessionCollection()
        #expect(collection.importSessions([imported]) == 1)
        #expect(collection[id]?.emoji == .historical)
        #expect(collection.consume(event(id, .sessionStart, at: 5, source: "resume")) != nil)
        #expect(collection[id]?.resumeCount == 1)
        #expect(collection[id]?.workflow == .inProgress)
        #expect(collection[id]?.emoji != .historical)

        _ = collection.consume(event(id, .stopFailure, at: 6))
        _ = collection.consume(event(id, .sessionEnd, at: 7), rules: OrganizationRules(backlogFailedSessions: true))
        #expect(collection[id]?.workflow == .backlog)

        collection.delete(id)
        #expect(collection[id] == nil)
        #expect(collection.importSessions([imported]) == 0)
        #expect(collection.tombstones.contains(id))
        #expect(collection.consume(event(id, .sessionStart, at: 8, source: "resume")) != nil)
        #expect(!collection.tombstones.contains(id))
    }

    @Test("Activity details are capped without pruning lifetime totals")
    func activityRetention() {
        let id = SessionID(provider: .codex, externalID: "long")
        var session = activeSession(id: id, at: 0)
        for offset in 1...(SessionActivityRecorder.detailLimit + 2) {
            let value = event(id, .preToolUse, at: TimeInterval(offset), tool: "Read")
            #expect(SessionReducer.reduce(value, into: &session))
        }
        #expect(session.activities.count == SessionActivityRecorder.detailLimit)
        #expect(session.activitySummary.toolCount == SessionActivityRecorder.detailLimit + 2)
    }

    private func activeSession(id: SessionID, at offset: TimeInterval) -> Session {
        Session(
            id: id,
            sourceTitle: "",
            emoji: .automatic("🦓"),
            cwd: "/tmp/project",
            createdAt: base,
            updatedAt: base.addingTimeInterval(offset),
            lifecycle: .active(ActiveSessionState(status: .waitingForInput))
        ).withProcess(process)
    }

    private func event(
        _ id: SessionID,
        _ kind: AgentEvent.Kind,
        at offset: TimeInterval,
        tool: String? = nil,
        source: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            sessionID: id,
            kind: kind,
            timestamp: base.addingTimeInterval(offset),
            cwd: "/tmp/project",
            process: process,
            toolName: tool,
            startSource: source
        )
    }
}

private extension Session {
    func withProcess(_ value: AgentProcessIdentity) -> Session {
        var copy = self
        copy.process = value
        return copy
    }
}
