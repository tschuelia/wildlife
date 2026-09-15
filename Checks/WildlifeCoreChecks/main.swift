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

@main
struct WildlifeCoreChecks {
    static func main() {
        do {
            try runCheck("resume templates", checkResumeTemplates)
            try runCheck("hook metadata boundary", checkHookMetadataBoundary)
            try runCheck("emoji allocation", checkEmojiAllocation)
            try runCheck("session persistence", checkSessionPersistence)
            try runCheck("backlog ordering", checkBacklogOrderPlanning)
            try runCheck("event reduction", checkEventReduction)
            try runCheck("local event transport", checkLocalEventTransport)
            try runCheck("hook configuration", checkHookConfiguration)
            try runCheck("notch geometry", checkNotchGeometry)
            try runCheck("process ancestry", checkProcessAncestry)
            try runCheck("historical import", checkHistoricalImport)
            print("WildlifeCoreChecks: \(checkCount) checks passed")
        } catch {
            FileHandle.standardError.write(Data("WildlifeCoreChecks failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
