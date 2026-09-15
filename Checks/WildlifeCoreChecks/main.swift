import CSQLite
import CoreGraphics
import Darwin
import Foundation
import WildlifeCore

private enum CheckFailure: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

nonisolated(unsafe) private var checkCount = 0

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BridgeEvent?

    func store(_ event: BridgeEvent) {
        lock.lock()
        stored = event
        lock.unlock()
    }

    var event: BridgeEvent? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
    checkCount += 1
}

private func runCheck(_ name: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        throw CheckFailure.failed("\(name): \(error.localizedDescription)")
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WildlifeChecks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func checkResumeTemplates() throws {
    let command = try ResumeCommandTemplate.render(
        "cd {{cwd}} && runner codex resume {{session_id}}",
        sessionID: "abc'def",
        cwd: "/tmp/My Project"
    )
    try check(command == "cd '/tmp/My Project' && runner codex resume 'abc'\\''def'", "Resume values were not shell quoted")
    do {
        try ResumeCommandTemplate.validate("codex resume latest")
        throw CheckFailure.failed("Template without session ID was accepted")
    } catch ResumeTemplateError.missingSessionID {
        checkCount += 1
    }
    do {
        try ResumeCommandTemplate.validate("codex resume {{session_id}} {{title}}")
        throw CheckFailure.failed("Unknown placeholder was accepted")
    } catch ResumeTemplateError.unknownPlaceholder("{{title}}") {
        checkCount += 1
    }
}

private func checkHookMetadataBoundary() throws {
    let sentinel = "CONTENT-MUST-NOT-LEAVE-HOOK"
    let payload: [String: Any] = [
        "session_id": "session-allowlist",
        "hook_event_name": "PostToolUse",
        "cwd": "/tmp/project",
        "model": "local-model-name",
        "tool_name": "Read",
        "prompt": sentinel,
        "transcript_path": "/tmp/\(sentinel).jsonl",
        "tool_input": ["command": sentinel],
        "tool_response": ["content": sentinel],
        "last_assistant_message": sentinel,
        "compact_summary": sentinel,
        "message": sentinel,
    ]
    let input = try JSONSerialization.data(withJSONObject: payload)
    let event = try BridgeEventFactory.decodeHookInput(
        input,
        provider: .claude,
        fallbackCWD: "/tmp/fallback",
        process: nil
    )
    try check(event.sessionID == "session-allowlist", "Hook session metadata was not decoded")
    try check(event.toolName == "Read" && event.model == "local-model-name", "Allowed hook metadata was lost")
    try check(event.isValidForTransport, "Metadata-only hook event failed validation")

    let encoded = try JSONEncoder().encode(event)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    try check(!encodedText.contains(sentinel), "Content-bearing hook data entered the bridge event")
    for forbiddenKey in ["prompt", "transcript_path", "tool_input", "tool_response", "last_assistant_message", "compact_summary"] {
        try check(!encodedText.contains(forbiddenKey), "Bridge event serialized forbidden key \(forbiddenKey)")
    }

    let unsupported = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-allowlist",
        "hook_event_name": "UnknownFutureEvent",
    ])
    do {
        _ = try BridgeEventFactory.decodeHookInput(
            unsupported,
            provider: .claude,
            fallbackCWD: "/tmp/fallback",
            process: nil
        )
        throw CheckFailure.failed("Unsupported hook event was accepted")
    } catch is DecodingError {
        checkCount += 1
    }
}

private func checkEmojiAllocation() throws {
    let first = EmojiAllocator.next(used: [])
    let second = EmojiAllocator.next(used: [first])
    try check(first == EmojiAllocator.orderedPool.first, "Emoji pool order changed")
    try check(second != first, "Emoji allocation was not unique")
    try check(EmojiAllocator.isSingleEmoji("🦓"), "Simple emoji was rejected")
    try check(EmojiAllocator.isSingleEmoji("🐻‍❄️"), "Joined emoji was rejected")
    try check(EmojiAllocator.isSingleEmoji("🇩🇪"), "Flag emoji was rejected")
    try check(EmojiAllocator.isSingleEmoji("©️"), "Emoji presentation selector was rejected")
    try check(EmojiAllocator.isSingleEmoji("1️⃣"), "Keycap emoji was rejected")
    try check(!EmojiAllocator.isSingleEmoji("🦓🦉"), "Two emoji were accepted as an override")
    try check(!EmojiAllocator.isSingleEmoji("A"), "Plain text was accepted as an emoji")
    try check(!EmojiAllocator.isSingleEmoji("1"), "Plain digit was accepted as an emoji")
    try check(!EmojiAllocator.isSingleEmoji("#"), "Plain hash was accepted as an emoji")
    try check(!EmojiAllocator.isSingleEmoji("*"), "Plain asterisk was accepted as an emoji")
    try check(!EmojiAllocator.isSingleEmoji("©"), "Text-presentation symbol was accepted as an emoji")
    try check(EmojiAllocator.isAutomaticallyAllocated(first), "A pooled emoji was not recognized as automatic")
    try check(EmojiAllocator.isAutomaticallyAllocated("🐾42"), "A fallback emoji was not recognized as automatic")
    try check(!EmojiAllocator.isAutomaticallyAllocated("😀"), "An outside emoji was classified as automatic")
}

private func sessionFixture(
    provider: AgentProvider = .claude,
    id: String,
    emoji: String = "🦓",
    updatedAt: Date,
    workflow: WorkflowBucket = .completed,
    customized: Bool = false
) -> SessionRecord {
    SessionRecord(
        provider: provider,
        sessionID: id,
        sourceTitle: id,
        emoji: emoji,
        cwd: "/tmp/project",
        createdAt: updatedAt,
        updatedAt: updatedAt,
        workflow: workflow,
        runtimeStatus: workflow == .inProgress ? .waitingForInput : .ended,
        emojiWasCustomized: customized
    )
}

private func checkSessionHistoryPolicy() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let recent = sessionFixture(id: "recent", emoji: "🦓", updatedAt: now.addingTimeInterval(-86_400))
    recent.endedAt = now.addingTimeInterval(-3_599)
    let boundary = sessionFixture(id: "boundary", emoji: "🦒", updatedAt: now)
    boundary.endedAt = now.addingTimeInterval(-3_600)
    let missingCompletion = sessionFixture(id: "missing-completion", emoji: "🐯", updatedAt: now)
    let customized = sessionFixture(
        id: "custom",
        emoji: "😀",
        updatedAt: now.addingTimeInterval(-8 * 86_400),
        customized: true
    )
    customized.endedAt = now.addingTimeInterval(-8 * 86_400)
    let active = sessionFixture(
        id: "active",
        emoji: "🐘",
        updatedAt: now.addingTimeInterval(-30 * 86_400),
        workflow: .inProgress
    )
    let backlog = sessionFixture(
        id: "backlog",
        emoji: "🦁",
        updatedAt: now.addingTimeInterval(-30 * 86_400),
        workflow: .backlog
    )
    backlog.endedAt = now.addingTimeInterval(-30 * 86_400)

    try check(SessionHistoryPolicy.isVisibleByDefault(recent, now: now), "A recent session was hidden")
    try check(!SessionHistoryPolicy.isVisibleByDefault(backlog, now: now), "An old inactive session was visible by default")
    try check(SessionHistoryPolicy.isVisibleByDefault(active, now: now), "An old active session was hidden")
    let sessions = [recent, boundary, missingCompletion, customized, active, backlog]
    try check(
        SessionHistoryPolicy.reservedEmojis(in: sessions, now: now) == ["🦓", "😀", "🐘", "🦁"],
        "Expired emojis remained reserved before normalization"
    )
    try check(
        SessionHistoryPolicy.releaseOldAutomaticEmojis(in: sessions, now: now) == 2,
        "Completed emoji normalization changed the wrong number of sessions"
    )
    try check(recent.emoji == "🦓", "A recent completion released its emoji too early")
    try check(boundary.emoji == SessionHistoryPolicy.historicalEmoji, "An emoji survived the one-hour boundary")
    try check(missingCompletion.emoji == SessionHistoryPolicy.historicalEmoji, "A completion without an end time retained an emoji")
    try check(customized.emoji == "😀", "A customized old emoji was overwritten")
    try check(active.emoji == "🐘", "An active session released its emoji")
    try check(backlog.emoji == "🦁", "A backlog session released its emoji")
    let reserved = SessionHistoryPolicy.reservedEmojis(in: sessions, now: now)
    try check(reserved == ["🦓", "😀", "🐘", "🦁"], "Released emojis still reserved preferred choices")
}

private func checkSessionSupersession() throws {
    let old = sessionFixture(
        id: "old-active",
        updatedAt: Date(timeIntervalSince1970: 100),
        workflow: .inProgress
    )
    old.processID = 123
    old.processStartIdentity = "same-start"
    old.tty = "/dev/ttys001"
    let unrelated = sessionFixture(
        id: "unrelated",
        updatedAt: Date(timeIntervalSince1970: 100),
        workflow: .inProgress
    )
    unrelated.processID = 456
    unrelated.processStartIdentity = "other-start"
    unrelated.tty = "/dev/ttys002"
    let otherProvider = sessionFixture(
        provider: .codex,
        id: "other-provider",
        updatedAt: Date(timeIntervalSince1970: 100),
        workflow: .inProgress
    )
    otherProvider.processID = 123
    otherProvider.processStartIdentity = "same-start"
    otherProvider.tty = "/dev/ttys001"
    let clear = BridgeEvent(
        provider: .claude,
        sessionID: "replacement",
        lifecycleEvent: "SessionStart",
        timestamp: Date(timeIntervalSince1970: 110),
        cwd: "/tmp/project",
        processID: 123,
        processStartIdentity: "same-start",
        tty: "/dev/ttys001",
        startSource: "clear"
    )

    try check(
        SessionSupersession.finishSessionsSuperseded(by: clear, in: [old, unrelated, otherProvider]) == 1,
        "Clear did not supersede exactly one prior session"
    )
    try check(old.workflow == .completed && old.endedAt == clear.timestamp, "Cleared session remained active")
    try check(old.activities.last?.endReason == "clear", "Clear reason was not retained")
    try check(unrelated.workflow == .inProgress, "Clear superseded another process")
    try check(otherProvider.workflow == .inProgress, "Clear superseded another provider")

    let ordinary = sessionFixture(
        id: "ordinary-start-source",
        updatedAt: Date(timeIntervalSince1970: 111),
        workflow: .inProgress
    )
    ordinary.processID = 777
    ordinary.processStartIdentity = "ordinary-process"
    let ordinaryStart = BridgeEvent(
        provider: .claude,
        sessionID: "ordinary-replacement",
        lifecycleEvent: "SessionStart",
        timestamp: Date(timeIntervalSince1970: 112),
        cwd: "/tmp/project",
        processID: 777,
        processStartIdentity: "ordinary-process"
    )
    try check(
        SessionSupersession.finishSessionsSuperseded(by: ordinaryStart, in: [ordinary]) == 1
            && ordinary.workflow == .completed,
        "A replacement start without a clear/resume source left the prior session active"
    )

    let ttyOnly = sessionFixture(
        id: "tty-only",
        updatedAt: Date(timeIntervalSince1970: 115),
        workflow: .inProgress
    )
    ttyOnly.tty = "/dev/ttys003"
    let ttyResume = BridgeEvent(
        provider: .claude,
        sessionID: "tty-replacement",
        lifecycleEvent: "SessionStart",
        timestamp: Date(timeIntervalSince1970: 120),
        cwd: "/tmp/project",
        tty: "/dev/ttys003",
        startSource: "resume"
    )
    try check(
        SessionSupersession.finishSessionsSuperseded(by: ttyResume, in: [ttyOnly]) == 1
            && ttyOnly.workflow == .completed,
        "TTY fallback did not supersede an identity without process metadata"
    )

    let forked = sessionFixture(
        id: "fork-source",
        updatedAt: Date(timeIntervalSince1970: 120),
        workflow: .inProgress
    )
    forked.processID = 123
    forked.processStartIdentity = "same-start"
    let fork = BridgeEvent(
        provider: .claude,
        sessionID: "fork-target",
        lifecycleEvent: "SessionStart",
        timestamp: Date(timeIntervalSince1970: 130),
        cwd: "/tmp/project",
        processID: 123,
        processStartIdentity: "same-start",
        startSource: "fork"
    )
    try check(
        SessionSupersession.finishSessionsSuperseded(by: fork, in: [forked]) == 0
            && forked.workflow == .inProgress,
        "A fork incorrectly superseded its source session"
    )

    let stale = sessionFixture(
        id: "persisted-stale",
        updatedAt: Date(timeIntervalSince1970: 200),
        workflow: .inProgress
    )
    stale.processID = 900
    stale.processStartIdentity = "persisted-start"
    let newest = sessionFixture(
        id: "persisted-newest",
        updatedAt: Date(timeIntervalSince1970: 210),
        workflow: .inProgress
    )
    newest.processID = 900
    newest.processStartIdentity = "persisted-start"
    let recycled = sessionFixture(
        id: "recycled-pid",
        updatedAt: Date(timeIntervalSince1970: 205),
        workflow: .inProgress
    )
    recycled.processID = 900
    recycled.processStartIdentity = "different-start"
    let persistedFork = sessionFixture(
        id: "persisted-fork",
        updatedAt: Date(timeIntervalSince1970: 215),
        workflow: .inProgress
    )
    persistedFork.processID = 900
    persistedFork.processStartIdentity = "persisted-start"
    persistedFork.isForkedSession = true
    try check(
        SessionSupersession.reconcilePersistedActiveSessions(in: [stale, newest, recycled, persistedFork]) == 1,
        "Persisted duplicate reconciliation changed the wrong records"
    )
    try check(stale.workflow == .completed && newest.workflow == .inProgress, "Newest persisted session was not retained")
    try check(recycled.workflow == .inProgress, "A recycled PID was treated as the same agent process")
    try check(persistedFork.workflow == .inProgress, "A persisted fork was treated as a stale duplicate")

    let launchTime = Date(timeIntervalSince1970: 220)
    let deadAtLaunch = sessionFixture(id: "dead-at-launch", updatedAt: launchTime, workflow: .inProgress)
    deadAtLaunch.processID = 901
    let reusedAtLaunch = sessionFixture(id: "reused-at-launch", updatedAt: launchTime, workflow: .inProgress)
    reusedAtLaunch.processID = 902
    let aliveAtLaunch = sessionFixture(id: "alive-at-launch", updatedAt: launchTime, workflow: .inProgress)
    aliveAtLaunch.processID = 903
    let unknownAtLaunch = sessionFixture(id: "unknown-at-launch", updatedAt: launchTime, workflow: .inProgress)
    unknownAtLaunch.processID = 904
    let pidlessAtLaunch = sessionFixture(id: "pidless-at-launch", updatedAt: launchTime, workflow: .inProgress)
    try check(
        SessionSupersession.finishDefinitivelyDeadSessions(
            in: [deadAtLaunch, reusedAtLaunch, aliveAtLaunch, unknownAtLaunch, pidlessAtLaunch],
            liveness: { pid, _ in
                switch pid {
                case 901: .notRunning
                case 902: .identityMismatch
                case 903: .matching
                default: .unknown
                }
            }
        ) == 2,
        "Startup cleanup did not close exactly the definitively dead sessions"
    )
    try check(deadAtLaunch.workflow == .completed, "A missing startup process remained active")
    try check(reusedAtLaunch.workflow == .completed, "A reused startup PID remained active")
    try check(aliveAtLaunch.workflow == .inProgress, "A live startup process was closed")
    try check(unknownAtLaunch.workflow == .inProgress, "An uninspectable startup process was closed")
    try check(pidlessAtLaunch.workflow == .inProgress, "A PID-less startup session was closed")
}

private func checkSessionPersistence() throws {
    struct LegacyState: Encodable {
        let schemaVersion: Int
        let sessions: [SessionRecord]
    }

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Sessions.json")
    let session = SessionRecord(
        provider: .codex,
        sessionID: "persisted-session",
        sourceTitle: "Persisted",
        emoji: "🦓",
        cwd: "/tmp/project",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        workflow: .completed,
        runtimeStatus: .ended
    )
    session.stableKey = "forged:key"
    let newer = SessionRecord(
        provider: .codex,
        sessionID: session.sessionID,
        sourceTitle: "Newest",
        emoji: "🦉",
        cwd: "/tmp/project",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 3),
        workflow: .completed,
        runtimeStatus: .ended
    )
    let invalid = SessionRecord(
        provider: .claude,
        sessionID: "invalid-provider",
        sourceTitle: "Invalid",
        emoji: "🦊",
        cwd: "/tmp/project",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 4),
        workflow: .completed,
        runtimeStatus: .ended
    )
    invalid.providerRaw = "unknown"
    let encoder = JSONEncoder()
    try encoder.encode(LegacyState(schemaVersion: 1, sessions: [session, newer, invalid])).write(to: url)

    let store = SessionDiskStore(url: url)
    let migrated = try store.loadState()
    try check(migrated.sessions.map(\.stableKey) == ["codex:persisted-session"], "Persisted identity was not canonicalized")
    try check(migrated.sessions.first?.sourceTitle == "Newest", "Newest duplicate session was not retained")
    try check(migrated.deletedSessionKeys.isEmpty, "Schema-1 state gained deletion tombstones")

    try store.save(PersistedSessions(
        sessions: migrated.sessions,
        deletedSessionKeys: ["codex:z", "claude:a", "codex:z", "invalid:key"]
    ))
    try check(chmod(url.path, 0o644) == 0, "Could not prepare permissive session-state fixture")
    let reloaded = try store.loadState()
    try check(reloaded.schemaVersion == PersistedSessions.currentSchemaVersion, "Session state schema was not upgraded")
    try check(reloaded.deletedSessionKeys == ["claude:a", "codex:z"], "Deletion tombstones were not normalized")
    try check(reloaded.sessions.map(\.stableKey) == ["codex:persisted-session"], "Saving tombstones lost sessions")

    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    try check(directoryMode?.intValue == 0o700, "Session directory was not private")
    try check(fileMode?.intValue == 0o600, "Session state was not private")

    let sentinel = directory.appendingPathComponent("outside-sentinel")
    let link = directory.appendingPathComponent("spool-link.json")
    try Data("outside".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
    do {
        _ = try SecureLocalFile.readPrivateFile(at: link)
        throw CheckFailure.failed("Private-file reader followed a symbolic link")
    } catch is LocalSecurityError {
        checkCount += 1
    }
    try SecureLocalFile.removeOwnedFileOrLink(at: link)
    let sentinelData = try Data(contentsOf: sentinel)
    try check(sentinelData == Data("outside".utf8), "Removing a spool link changed its target")
    try check(RuntimePaths.spoolURL(eventID: "../../outside-sentinel") == nil, "Path-traversal event ID produced a spool URL")
}

private func checkBacklogOrderPlanning() throws {
    try check(
        BacklogOrderPlanner.moving("d", before: "b", in: ["a", "b", "c", "d"]) == ["a", "d", "b", "c"],
        "Backlog item did not move upward"
    )
    try check(
        BacklogOrderPlanner.moving("a", before: "d", in: ["a", "b", "c", "d"]) == ["b", "c", "a", "d"],
        "Backlog item did not move downward"
    )
    try check(
        BacklogOrderPlanner.moving("c", before: "a", in: ["a", "b", "c"]) == ["c", "a", "b"],
        "Backlog item did not move to the beginning"
    )
    try check(
        BacklogOrderPlanner.moving("a", before: nil, in: ["a", "b", "c"]) == ["b", "c", "a"],
        "Backlog item did not move to the end"
    )
    try check(
        BacklogOrderPlanner.moving("new", before: "b", in: ["a", "b", "c"]) == ["a", "new", "b", "c"],
        "A completed item was not inserted into backlog order"
    )
    try check(
        BacklogOrderPlanner.moving("b", before: "b", in: ["a", "b", "c"]) == ["a", "b", "c"],
        "Dropping an item on itself changed backlog order"
    )
    try check(
        BacklogOrderPlanner.moving("b", before: nil, in: ["a", "b", "a", "c"]) == ["a", "c", "b"],
        "Backlog planning retained duplicate keys"
    )
}

private func checkEventReduction() throws {
    let session = SessionRecord(
        provider: .codex,
        sessionID: "session-1",
        sourceTitle: "Test",
        emoji: "🦓",
        cwd: "/tmp/project",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        workflow: .completed,
        runtimeStatus: .ended
    )
    let resumed = BridgeEvent(
        eventID: "resume",
        provider: .codex,
        sessionID: session.sessionID,
        lifecycleEvent: "SessionStart",
        timestamp: Date(timeIntervalSince1970: 2),
        cwd: session.cwd,
        startSource: "resume"
    )
    try check(SessionEventReducer.apply(resumed, to: session), "Resume event was not applied")
    try check(session.workflow == .inProgress && session.resumeCount == 1, "Resume transition was incorrect")
    try check(session.createdAt == Date(timeIntervalSince1970: 1), "Resume overwrote the original session start")
    try check(!SessionEventReducer.apply(resumed, to: session), "Duplicate event was applied")

    let ended = BridgeEvent(
        eventID: "end",
        provider: .codex,
        sessionID: session.sessionID,
        lifecycleEvent: "SessionEnd",
        timestamp: Date(timeIntervalSince1970: 3),
        cwd: session.cwd
    )
    try check(SessionEventReducer.apply(ended, to: session), "End event was not applied")
    try check(session.workflow == .completed && session.runtimeStatus == .ended, "End transition was incorrect")

    let originalUpdate = session.updatedAt
    let otherSessionEvent = BridgeEvent(
        provider: .codex,
        sessionID: "session-2",
        lifecycleEvent: "SessionStart",
        timestamp: Date(timeIntervalSince1970: 4),
        cwd: "/tmp/other"
    )
    try check(!SessionEventReducer.apply(otherSessionEvent, to: session), "Another session mutated the target session")
    try check(session.updatedAt == originalUpdate && session.cwd == "/tmp/project", "Rejected session event changed metadata")

    let otherProviderEvent = BridgeEvent(
        provider: .claude,
        sessionID: session.sessionID,
        lifecycleEvent: "SessionStart",
        timestamp: Date(timeIntervalSince1970: 5),
        cwd: "/tmp/claude"
    )
    try check(!SessionEventReducer.apply(otherProviderEvent, to: session), "Another provider mutated the target session")

    let missingStart = sessionFixture(
        id: "missing-start",
        updatedAt: Date(timeIntervalSince1970: 10),
        workflow: .completed
    )
    missingStart.createdAt = .distantPast
    let startTimestamp = Date(timeIntervalSince1970: 11)
    let start = BridgeEvent(
        eventID: "missing-start-event",
        provider: missingStart.provider,
        sessionID: missingStart.sessionID,
        lifecycleEvent: "SessionStart",
        timestamp: startTimestamp,
        cwd: missingStart.cwd
    )
    try check(SessionEventReducer.apply(start, to: missingStart), "Start event was not applied to a legacy session")
    try check(missingStart.createdAt == startTimestamp, "A known start time did not repair missing session metadata")
}

private func checkLocalEventTransport() throws {
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("WildlifeSocket-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketURL = directory.appendingPathComponent("events.sock")
    let server = LocalEventServer(socketURL: socketURL)
    defer { server.stop() }
    let received = EventBox()
    let delivered = DispatchSemaphore(value: 0)
    try server.start { event in
        received.store(event)
        delivered.signal()
    }

    let socketMode = try FileManager.default.attributesOfItem(atPath: socketURL.path)[.posixPermissions] as? NSNumber
    try check(socketMode?.intValue == 0o600, "Event socket was not private before use")
    try check(LocalEventTransport.peerUIDIsAllowed(geteuid()), "Current-user peer was rejected")
    try check(!LocalEventTransport.peerUIDIsAllowed(geteuid() &+ 1), "Another-user peer was accepted")

    let event = BridgeEvent(
        provider: .codex,
        sessionID: "transport-session",
        lifecycleEvent: "SessionStart",
        cwd: "/tmp/project",
        processID: Int32(ProcessInfo.processInfo.processIdentifier)
    )
    let data = try JSONEncoder().encode(event)
    try check(LocalEventTransport.send(data, to: socketURL), "Authenticated local event send failed")
    try check(delivered.wait(timeout: .now() + 3) == .success, "Local event was not delivered")
    try check(received.event == event, "Local event changed during transport")
    try check(
        !LocalEventTransport.send(Data(repeating: 0, count: LocalEventTransport.maximumPayloadSize + 1), to: socketURL),
        "Oversized local event was sent"
    )

    let occupiedURL = directory.appendingPathComponent("occupied.sock")
    let sentinel = Data("do-not-delete".utf8)
    try sentinel.write(to: occupiedURL)
    let conflictingServer = LocalEventServer(socketURL: occupiedURL)
    var rejectedOccupiedPath = false
    do {
        try conflictingServer.start { _ in }
    } catch {
        rejectedOccupiedPath = true
    }
    try check(rejectedOccupiedPath, "Server replaced an unexpected socket-path entry")
    let occupiedData = try Data(contentsOf: occupiedURL)
    try check(occupiedData == sentinel, "Server changed an unexpected socket-path entry")
}

private func checkHookConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("settings.json")
    let original: [String: Any] = [
        "theme": "dark",
        "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "existing-hook"]]]]],
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: config)
    let bridge = directory.appendingPathComponent("wildlife-hook")
    let first = try HookConfiguration.install(provider: .claude, configURL: config, bridgeURL: bridge)
    let second = try HookConfiguration.install(provider: .claude, configURL: config, bridgeURL: bridge)
    try check(first.changed && first.backupURL != nil, "Hook installation did not create a backup")
    try check(!second.changed, "Hook installation was not idempotent")
    try check(HookConfiguration.isInstalled(provider: .claude, configURL: config, bridgeURL: bridge), "Installed hook was not detected")
    let configMode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
    let backupMode = try first.backupURL.flatMap {
        try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber
    }
    try check(configMode?.intValue == 0o600, "Hook configuration was not made private")
    try check(backupMode?.intValue == 0o600, "Hook configuration backup was not private")
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
    try check(root?["theme"] as? String == "dark", "Existing configuration was not preserved")

    let claudeHooks = root?["hooks"] as? [String: Any]
    let claudeStartGroups = claudeHooks?["SessionStart"] as? [[String: Any]]
    let claudeEndGroups = claudeHooks?["SessionEnd"] as? [[String: Any]]
    let command = HookConfiguration.hookCommand(bridgeURL: bridge, provider: .claude)
    let claudeStart = claudeStartGroups?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        .first { $0["command"] as? String == command }
    let claudeEnd = claudeEndGroups?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        .first { $0["command"] as? String == command }
    try check(claudeStart?["async"] == nil, "Claude's lifecycle hook was not synchronous")
    try check(claudeEnd?["async"] == nil, "Claude's SessionEnd hook was not synchronous")

    var staleClaudeRoot = root!
    var staleClaudeHooks = staleClaudeRoot["hooks"] as! [String: Any]
    for event in ["SessionStart", "SessionEnd"] {
        var groups = staleClaudeHooks[event] as! [[String: Any]]
        var handlers = groups.last!["hooks"] as! [[String: Any]]
        let wildlifeIndex = handlers.firstIndex { $0["command"] as? String == command }!
        handlers[wildlifeIndex]["async"] = true
        groups[groups.index(before: groups.endIndex)]["hooks"] = handlers
        staleClaudeHooks[event] = groups
    }
    staleClaudeRoot["hooks"] = staleClaudeHooks
    try JSONSerialization.data(withJSONObject: staleClaudeRoot).write(to: config)
    try check(
        HookConfiguration.installationState(provider: .claude, configURL: config, bridgeURL: bridge) == .needsRepair,
        "Stale Claude handlers were not flagged for repair"
    )
    let repairedClaude = try HookConfiguration.repairExistingHandlers(
        provider: .claude,
        configURL: config,
        bridgeURL: bridge
    )
    try check(repairedClaude.changed, "Claude handlers were not repaired")
    try check(
        HookConfiguration.installationState(provider: .claude, configURL: config, bridgeURL: bridge) == .installed,
        "Repaired Claude handlers were not recognized as installed"
    )
    let repairedClaudeRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    let repairedClaudeHooks = repairedClaudeRoot["hooks"] as! [String: Any]
    let allClaudeHandlersAreSynchronous = HookConfiguration.claudeEvents.allSatisfy { event in
        guard let groups = repairedClaudeHooks[event] as? [[String: Any]] else { return false }
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { $0["command"] as? String == command }
            .allSatisfy { $0["async"] == nil }
    }
    try check(allClaudeHandlersAreSynchronous, "Claude repair left asynchronous Wildlife handlers")

    let removed = try HookConfiguration.uninstall(provider: .claude, configURL: config, bridgeURL: bridge)
    try check(removed.changed, "Hook uninstall made no change")
    let final = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
    let hooks = final?["hooks"] as? [String: Any]
    let groups = hooks?["SessionStart"] as? [[String: Any]]
    let existingRemains = groups?.contains { group in
        (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == "existing-hook" } == true
    } == true
    try check(existingRemains, "Uninstall removed a third-party hook")

    let codexConfig = directory.appendingPathComponent("codex-hooks.json")
    _ = try HookConfiguration.install(provider: .codex, configURL: codexConfig, bridgeURL: bridge)
    var codexRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: codexConfig)) as! [String: Any]
    var codexHooks = codexRoot["hooks"] as! [String: Any]
    for event in HookConfiguration.codexEvents {
        var groups = codexHooks[event] as! [[String: Any]]
        var handlers = groups[0]["hooks"] as! [[String: Any]]
        handlers[0]["async"] = true
        groups[0]["hooks"] = handlers
        codexHooks[event] = groups
    }
    codexRoot["hooks"] = codexHooks
    try JSONSerialization.data(withJSONObject: codexRoot).write(to: codexConfig)

    try check(
        HookConfiguration.installationState(provider: .codex, configURL: codexConfig, bridgeURL: bridge) == .needsRepair,
        "Obsolete Codex async handlers were not flagged for repair"
    )
    let repaired = try HookConfiguration.repairExistingHandlers(
        provider: .codex,
        configURL: codexConfig,
        bridgeURL: bridge
    )
    try check(repaired.changed, "Codex hook repair made no change")
    try check(repaired.backupURL != nil, "Codex hook repair did not create a backup")
    try check(
        HookConfiguration.installationState(provider: .codex, configURL: codexConfig, bridgeURL: bridge) == .installed,
        "Repaired Codex handlers were not recognized as installed"
    )
    let repairedRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: codexConfig)) as! [String: Any]
    let repairedHooks = repairedRoot["hooks"] as! [String: Any]
    let codexCommand = HookConfiguration.hookCommand(bridgeURL: bridge, provider: .codex)
    let allCodexHandlersAreSynchronous = HookConfiguration.codexEvents.allSatisfy { event in
        guard let groups = repairedHooks[event] as? [[String: Any]] else { return false }
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { $0["command"] as? String == codexCommand }
            .allSatisfy { $0["async"] == nil }
    }
    try check(allCodexHandlersAreSynchronous, "Codex repair left an unsupported async option")
    let repairAgain = try HookConfiguration.repairExistingHandlers(
        provider: .codex,
        configURL: codexConfig,
        bridgeURL: bridge
    )
    try check(!repairAgain.changed && repairAgain.backupURL == nil, "Codex hook repair was not idempotent")

    let partialConfig = directory.appendingPathComponent("partial-hooks.json")
    let partialCommand = HookConfiguration.hookCommand(bridgeURL: bridge, provider: .codex)
    let partialRoot: [String: Any] = [
        "theme": "preserve-me",
        "hooks": [
            "SessionStart": [[
                "matcher": "keep-this-group-field",
                "hooks": [
                    [
                        "type": "command",
                        "command": partialCommand,
                        "timeout": 99,
                        "async": true,
                        "custom": "keep-this-handler-field",
                    ],
                    ["type": "command", "command": "third-party", "async": true],
                ],
            ]],
        ],
    ]
    try JSONSerialization.data(withJSONObject: partialRoot).write(to: partialConfig)
    let partialRepair = try HookConfiguration.repairExistingHandlers(
        provider: .codex,
        configURL: partialConfig,
        bridgeURL: bridge
    )
    try check(partialRepair.changed, "Partial Codex integration was not repaired")
    let partialFinal = try JSONSerialization.jsonObject(with: Data(contentsOf: partialConfig)) as! [String: Any]
    let partialHooks = partialFinal["hooks"] as! [String: Any]
    let partialGroups = partialHooks["SessionStart"] as! [[String: Any]]
    let partialHandlers = partialGroups[0]["hooks"] as! [[String: Any]]
    let wildlifeHandler = partialHandlers.first { $0["command"] as? String == partialCommand }
    try check(partialHooks["SessionEnd"] == nil, "Automatic repair installed a missing event")
    try check(partialFinal["theme"] as? String == "preserve-me", "Automatic repair changed a root setting")
    try check(partialGroups[0]["matcher"] as? String == "keep-this-group-field", "Automatic repair changed a hook group field")
    try check(wildlifeHandler?["custom"] as? String == "keep-this-handler-field", "Automatic repair removed an unknown handler field")
    try check(wildlifeHandler?["async"] == nil, "Partial Codex repair left async enabled")
    try check((wildlifeHandler?["timeout"] as? NSNumber)?.intValue == 2, "Partial Codex repair did not restore the timeout")
    try check(partialHandlers.contains { $0["command"] as? String == "third-party" }, "Automatic repair changed a third-party hook")
    try check(
        HookConfiguration.installationState(provider: .codex, configURL: partialConfig, bridgeURL: bridge) == .needsRepair,
        "Partial integration was incorrectly reported as fully installed"
    )

    let unrelatedConfig = directory.appendingPathComponent("unrelated-hooks.json")
    let unrelatedData = try JSONSerialization.data(withJSONObject: [
        "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "third-party"]]]]],
    ])
    try unrelatedData.write(to: unrelatedConfig)
    let unrelatedRepair = try HookConfiguration.repairExistingHandlers(
        provider: .codex,
        configURL: unrelatedConfig,
        bridgeURL: bridge
    )
    try check(!unrelatedRepair.changed && unrelatedRepair.backupURL == nil, "Automatic repair changed an absent integration")
    let unrelatedFinalData = try Data(contentsOf: unrelatedConfig)
    try check(unrelatedFinalData == unrelatedData, "Absent integration was rewritten")

    let malformedConfig = directory.appendingPathComponent("malformed-hooks.json")
    let malformedData = Data("{ not valid JSON".utf8)
    try malformedData.write(to: malformedConfig)
    var malformedThrew = false
    do {
        _ = try HookConfiguration.repairExistingHandlers(
            provider: .codex,
            configURL: malformedConfig,
            bridgeURL: bridge
        )
    } catch {
        malformedThrew = true
    }
    try check(malformedThrew, "Malformed hook configuration did not report an error")
    let malformedFinalData = try Data(contentsOf: malformedConfig)
    try check(malformedFinalData == malformedData, "Malformed hook configuration was modified")
}

private func checkNotchGeometry() throws {
    let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let left = CGRect(x: 0, y: 950, width: 663, height: 32)
    let right = CGRect(x: 848, y: 950, width: 664, height: 32)
    guard let geometry = NotchGeometry(
        screenFrame: screen,
        safeAreaTop: 32,
        auxiliaryTopLeftArea: left,
        auxiliaryTopRightArea: right
    ) else {
        throw CheckFailure.failed("Valid built-in notch geometry was rejected")
    }
    try check(geometry.notchFrame == CGRect(x: 663, y: 950, width: 185, height: 32), "Physical notch frame was calculated incorrectly")
    try check(geometry.compactFrame == CGRect(x: 633, y: 950, width: 245, height: 32), "Compact notch wings were calculated incorrectly")
    try check(geometry.leftWingWidth == 30 && geometry.rightWingWidth == 30, "Compact wing widths changed")
    try check(
        geometry.expandedFrame(width: 310, height: 400) == CGRect(x: 600.5, y: 582, width: 310, height: 400),
        "Expanded island was not centered and top-attached"
    )
    try check(
        geometry.panelFrame(expanded: false, expandedWidth: 310, expandedHeight: 400) == geometry.compactFrame,
        "Collapsed panel retained an expanded click-blocking frame"
    )
    try check(
        geometry.panelFrame(expanded: true, expandedWidth: 310, expandedHeight: 400)
            == geometry.expandedFrame(width: 310, height: 400),
        "Expanded panel did not use expanded geometry"
    )

    let translatedScreen = screen.offsetBy(dx: -1_512, dy: 120)
    let translated = NotchGeometry(
        screenFrame: translatedScreen,
        safeAreaTop: 32,
        auxiliaryTopLeftArea: left.offsetBy(dx: -1_512, dy: 120),
        auxiliaryTopRightArea: right.offsetBy(dx: -1_512, dy: 120)
    )
    try check(translated?.notchFrame == geometry.notchFrame.offsetBy(dx: -1_512, dy: 120), "Translated display geometry was not preserved")
    try check(
        NotchGeometry(screenFrame: screen, safeAreaTop: 0, auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right) == nil,
        "A notchless display was accepted"
    )
    try check(
        NotchGeometry(screenFrame: screen, safeAreaTop: 32, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: right) == nil,
        "Missing auxiliary geometry was accepted"
    )
}

private func checkProcessAncestry() throws {
    let processID = ProcessInfo.processInfo.processIdentifier
    try check(
        ProcessInspector.liveness(pid: processID, startIdentity: nil) == .matching,
        "The current process was not detected as live"
    )
    try check(
        ProcessInspector.requestTermination(pid: processID, startIdentity: nil) == .identityUnavailable,
        "Termination was not refused when process identity was unavailable"
    )
    let ancestors = ProcessInspector.ancestorProcessIDs(startingAt: processID)
    try check(ancestors.first == processID, "Process ancestry did not begin with the requested process")
    try check(Set(ancestors).count == ancestors.count, "Process ancestry contained a cycle")
    try check(ProcessInspector.ancestorProcessIDs(startingAt: processID, limit: 1) == [processID], "Process ancestry ignored its traversal limit")
    try check(ProcessInspector.ancestorProcessIDs(startingAt: 1).isEmpty, "Process ancestry included launchd")
}

private func checkHistoricalImport() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("state_5.sqlite")
    var database: OpaquePointer?
    try check(sqlite3_open(databaseURL.path, &database) == SQLITE_OK, "Could not create fixture database")
    defer { sqlite3_close(database) }
    let schema = """
    CREATE TABLE threads (
      id TEXT, title TEXT, cwd TEXT, created_at INTEGER, updated_at INTEGER,
      created_at_ms INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER,
      source TEXT, has_user_event INTEGER, thread_source TEXT
    );
    INSERT INTO threads VALUES ('root','A title','/tmp/a',100,200,100000,200000,200000,'cli',0,'user');
    INSERT INTO threads VALUES ('exec','Ignore','/tmp/b',100,200,100000,200000,200000,'exec',1,'user');
    INSERT INTO threads VALUES ('sub','Ignore','/tmp/c',100,200,100000,200000,200000,'cli',1,'subagent');
    """
    try check(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK, "Could not seed fixture database")
    let codex = HistoricalImporter().importCodex(databaseURL: databaseURL, since: Date(timeIntervalSince1970: 0))
    try check(codex.map(\.sessionID) == ["root"], "Codex import did not filter noninteractive or subagent rows")

    let projects = directory.appendingPathComponent("projects", isDirectory: true)
    let project = projects.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let index: [String: Any] = [
        "entries": [[
            "sessionId": "claude-root",
            "summary": "Local summary",
            "firstPrompt": "must not be used",
            "projectPath": "/tmp/project",
            "created": "2026-01-01T00:00:00.000Z",
            "modified": "2026-01-02T00:00:00.000Z",
            "isSidechain": false,
        ]]
    ]
    try JSONSerialization.data(withJSONObject: index).write(to: project.appendingPathComponent("sessions-index.json"))
    let claude = HistoricalImporter().importClaude(projectsURL: projects, since: .distantPast)
    try check(claude.count == 1 && claude.first?.title == "Local summary", "Claude local index import failed")
    try check(!claude.contains { $0.title == "must not be used" }, "Claude first prompt leaked into imported metadata")
}

private func checkSessionIntelligencePersistence() throws {
    let legacy = Data(#"{"providerRaw":"codex","sessionID":"legacy-session"}"#.utf8)
    let migrated = try JSONDecoder().decode(SessionRecord.self, from: legacy)
    try check(migrated.activities.isEmpty, "Legacy session gained activity details")
    try check(migrated.activitySummary == SessionActivitySummary(), "Legacy session gained activity rollups")
    try check(migrated.tags.isEmpty && !migrated.isPinned, "Legacy session gained organization metadata")
    try check(migrated.archivedAt == nil && migrated.attentionSnoozedUntil == nil, "Legacy session gained lifecycle dates")
    try check(!migrated.emojiWasCustomized, "Legacy fallback emoji was treated as customized")

    let metadata = ProjectMetadata(
        repositoryRoot: "/tmp/repository",
        worktreeRoot: "/tmp/repository-feature",
        gitCommonDirectory: "/tmp/repository/.git",
        branch: "feature/saved-views"
    )
    migrated.projectMetadata = metadata
    migrated.tags = ["urgent", "backend"]
    migrated.isPinned = true
    migrated.emojiWasCustomized = true
    migrated.isForkedSession = true
    migrated.activitySummary.toolCount = 14
    migrated.activities = [SessionActivity(
        id: "metadata-event",
        timestamp: Date(timeIntervalSince1970: 10),
        eventName: "PreToolUse",
        status: .runningTool,
        toolName: "Read",
        endReason: nil,
        notificationType: nil,
        subagentCount: 0
    )]
    let roundTripped = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(migrated))
    try check(roundTripped.projectMetadata == metadata, "Git project metadata was not persisted")
    try check(roundTripped.tags == ["urgent", "backend"] && roundTripped.isPinned, "Organization metadata was not persisted")
    try check(roundTripped.emojiWasCustomized, "Emoji customization provenance was not persisted")
    try check(roundTripped.isForkedSession, "Fork provenance was not persisted")
    try check(roundTripped.activitySummary.toolCount == 14 && roundTripped.activities.count == 1, "Activity metadata was not persisted")
}

private func checkSessionActivityAndAttention() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let session = SessionRecord(
        provider: .claude,
        sessionID: "activity-session",
        sourceTitle: "Activity",
        emoji: "🦉",
        cwd: "/tmp/project",
        createdAt: start,
        updatedAt: start,
        workflow: .inProgress,
        runtimeStatus: .processing
    )
    let permission = BridgeEvent(
        eventID: UUID().uuidString,
        provider: .claude,
        sessionID: session.sessionID,
        lifecycleEvent: "PermissionRequest",
        timestamp: start.addingTimeInterval(10),
        cwd: session.cwd,
        toolName: "Bash"
    )
    session.runtimeStatus = .waitingForApproval
    SessionActivityRecorder.record(
        permission,
        previousStatus: .processing,
        previousWorkflow: .inProgress,
        previousEventAt: start,
        in: session
    )
    try check(session.activitySummary.activeDuration == 10, "Active duration was not rolled up")
    try check(session.activitySummary.permissionCount == 1, "Permission count was not recorded")
    try check(session.attentionReason(at: start.addingTimeInterval(11)) == .approval, "Approval attention was not detected")
    session.attentionSnoozedUntil = start.addingTimeInterval(100)
    try check(session.attentionReason(at: start.addingTimeInterval(11)) == nil, "Snoozed attention remained visible")
    try check(session.unsnoozedAttentionReason == .approval, "Snooze erased the underlying attention reason")

    for index in 0..<(SessionActivityRecorder.detailLimit + 2) {
        let event = BridgeEvent(
            eventID: UUID().uuidString,
            provider: .claude,
            sessionID: session.sessionID,
            lifecycleEvent: "PreToolUse",
            timestamp: start.addingTimeInterval(Double(20 + index)),
            cwd: session.cwd,
            toolName: "Read"
        )
        SessionActivityRecorder.record(
            event,
            previousStatus: .processing,
            previousWorkflow: .completed,
            previousEventAt: start,
            in: session
        )
    }
    try check(session.activities.count == SessionActivityRecorder.detailLimit, "Detailed activity retention was not capped")
    try check(session.activitySummary.toolCount == SessionActivityRecorder.detailLimit + 2, "Lifetime tool rollup was pruned with details")

    let failed = BridgeEvent(
        eventID: UUID().uuidString,
        provider: .claude,
        sessionID: session.sessionID,
        lifecycleEvent: "StopFailure",
        timestamp: start.addingTimeInterval(1_000),
        cwd: session.cwd
    )
    SessionActivityRecorder.record(
        failed,
        previousStatus: .processing,
        previousWorkflow: .completed,
        previousEventAt: start,
        in: session
    )
    try check(session.lastTurnOutcome == .failed, "Failure outcome was not retained for automation")
}

private func checkFilteringAndOrganization() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let session = SessionRecord(
        provider: .codex,
        sessionID: "filter-session",
        sourceTitle: "Release migration",
        emoji: "🦓",
        cwd: "/tmp/repository",
        createdAt: now.addingTimeInterval(-3_600),
        updatedAt: now.addingTimeInterval(-60),
        workflow: .inProgress,
        runtimeStatus: .waitingForInput
    )
    session.projectMetadata = ProjectMetadata(
        repositoryRoot: "/tmp/repository",
        worktreeRoot: "/tmp/repository",
        gitCommonDirectory: "/tmp/repository/.git",
        branch: "release"
    )
    session.tags = TagNormalizer.normalizeAll([" Urgent ", "backend", "URGENT", ""])
    session.isPinned = true
    try check(session.tags == ["backend", "urgent"], "Tags were not normalized and deduplicated")
    try check(SessionFilter(query: "release", providerRaws: ["codex"], projectKeys: [session.projectKey], tags: ["urgent"], recentDays: 1, pinnedOnly: true).matches(session, now: now), "Combined session filter rejected a match")
    try check(!SessionFilter(providerRaws: ["claude"]).matches(session, now: now), "Provider filter accepted another provider")
    try check(SessionFilter(attentionOnly: true).matches(session, now: now), "Attention view rejected waiting input")
    session.attentionSnoozedUntil = now.addingTimeInterval(60)
    try check(!SessionFilter(attentionOnly: true).matches(session, now: now), "Attention view retained a snoozed session")

    session.workflow = .completed
    session.runtimeStatus = .ended
    session.endedAt = now.addingTimeInterval(-31 * 86_400)
    session.isPinned = false
    let archiveRules = OrganizationRules(autoArchiveAfterDays: 30)
    try check(SessionOrganization.shouldAutoArchive(session, rules: archiveRules, now: now), "Expired completed session was not auto-archived")
    session.isPinned = true
    try check(!SessionOrganization.shouldAutoArchive(session, rules: archiveRules, now: now), "Pinned session was auto-archived")
    session.lastTurnOutcome = .failed
    try check(SessionOrganization.shouldMoveToBacklog(session, rules: OrganizationRules(backlogFailedSessions: true)), "Failed-session backlog rule did not apply")

    let sibling = SessionRecord(
        provider: .claude,
        sessionID: "sibling",
        sourceTitle: "Sibling",
        emoji: "🦊",
        cwd: session.cwd,
        createdAt: now,
        updatedAt: now,
        workflow: .inProgress,
        runtimeStatus: .processing
    )
    session.workflow = .inProgress
    sibling.projectMetadata = ProjectMetadata(
        repositoryRoot: "/tmp/repository",
        worktreeRoot: "/tmp/repository",
        gitCommonDirectory: "/tmp/repository/.git",
        branch: "release"
    )
    session.projectMetadata = sibling.projectMetadata
    try check(SessionOrganization.conflictingWorktreeKeys(in: [session, sibling]) == ["/tmp/repository"], "Shared active worktree was not flagged")
}

private func checkProjectInspectionAndActions() throws {
    let parsed = GitProjectInspector.parse(output: "/tmp/repository-worktree\n/tmp/repository/.git\nfeature/activity\n")
    try check(parsed?.repositoryRoot == "/tmp/repository", "Linked-worktree repository root was parsed incorrectly")
    try check(parsed?.worktreeRoot == "/tmp/repository-worktree", "Worktree root was parsed incorrectly")
    try check(parsed?.branch == "feature/activity", "Git branch was parsed incorrectly")
    try check(GitProjectInspector.parse(output: "missing\nlines\n") == nil, "Incomplete Git metadata was accepted")

    let escaped = AppleScriptEscaper.stringLiteral(#"one "two"\path"# + "\nnext")
    try check(escaped.contains(#"\"two\""#), "AppleScript quotes were not escaped")
    try check(escaped.contains(#"\\path"#), "AppleScript backslash was not escaped")
    try check(escaped.contains(" & linefeed & "), "AppleScript newline was not safely joined")

    let approval = BridgeEvent(provider: .codex, sessionID: "notify", lifecycleEvent: "PermissionRequest", cwd: "/tmp")
    let transition = SessionTransition(
        sessionKey: "codex:notify",
        event: approval,
        previousStatus: .runningTool,
        currentStatus: .waitingForApproval
    )
    try check(SessionNotificationDecision.kind(for: transition) == .approval, "Approval notification was not selected")
    let completion = BridgeEvent(provider: .codex, sessionID: "notify", lifecycleEvent: "SessionEnd", cwd: "/tmp")
    try check(SessionNotificationDecision.kind(for: SessionTransition(sessionKey: "codex:notify", event: completion, previousStatus: .waitingForInput, currentStatus: .ended)) == .completion, "Completion notification was not selected")
}

@main
struct WildlifeCoreChecks {
    static func main() {
        do {
            try runCheck("resume templates", checkResumeTemplates)
            try runCheck("hook metadata boundary", checkHookMetadataBoundary)
            try runCheck("emoji allocation", checkEmojiAllocation)
            try runCheck("session history policy", checkSessionHistoryPolicy)
            try runCheck("session supersession", checkSessionSupersession)
            try runCheck("session persistence", checkSessionPersistence)
            try runCheck("backlog ordering", checkBacklogOrderPlanning)
            try runCheck("event reduction", checkEventReduction)
            try runCheck("local event transport", checkLocalEventTransport)
            try runCheck("hook configuration", checkHookConfiguration)
            try runCheck("notch geometry", checkNotchGeometry)
            try runCheck("process ancestry", checkProcessAncestry)
            try runCheck("historical import", checkHistoricalImport)
            try runCheck("session intelligence persistence", checkSessionIntelligencePersistence)
            try runCheck("session activity and attention", checkSessionActivityAndAttention)
            try runCheck("filtering and organization", checkFilteringAndOrganization)
            try runCheck("project inspection and actions", checkProjectInspectionAndActions)
            print("WildlifeCoreChecks: \(checkCount) checks passed")
        } catch {
            FileHandle.standardError.write(Data("WildlifeCoreChecks failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
