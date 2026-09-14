import CSQLite
import CoreGraphics
import Foundation
import WildlifeCore

private enum CheckFailure: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

nonisolated(unsafe) private var checkCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
    checkCount += 1
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

private func checkEmojiAllocation() throws {
    let first = EmojiAllocator.next(used: [])
    let second = EmojiAllocator.next(used: [first])
    try check(first == EmojiAllocator.orderedPool.first, "Emoji pool order changed")
    try check(second != first, "Emoji allocation was not unique")
    try check(EmojiAllocator.isSingleEmoji("🦓"), "Simple emoji was rejected")
    try check(EmojiAllocator.isSingleEmoji("🐻‍❄️"), "Joined emoji was rejected")
    try check(!EmojiAllocator.isSingleEmoji("🦓🦉"), "Two emoji were accepted as an override")
    try check(!EmojiAllocator.isSingleEmoji("A"), "Plain text was accepted as an emoji")
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
    try check(claudeStart?["async"] as? Bool == true, "Claude's non-terminal hook was not asynchronous")
    try check(claudeEnd?["async"] == nil, "Claude's SessionEnd hook was incorrectly asynchronous")

    var staleClaudeRoot = root!
    var staleClaudeHooks = staleClaudeRoot["hooks"] as! [String: Any]
    for event in ["SessionStart", "SessionEnd"] {
        var groups = staleClaudeHooks[event] as! [[String: Any]]
        var handlers = groups.last!["hooks"] as! [[String: Any]]
        let wildlifeIndex = handlers.firstIndex { $0["command"] as? String == command }!
        handlers[wildlifeIndex]["async"] = event == "SessionEnd"
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
    INSERT INTO threads VALUES ('root','A title','/tmp/a',100,200,100000,200000,200000,'cli',1,'user');
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
            try checkResumeTemplates()
            try checkEmojiAllocation()
            try checkBacklogOrderPlanning()
            try checkEventReduction()
            try checkHookConfiguration()
            try checkNotchGeometry()
            try checkProcessAncestry()
            try checkHistoricalImport()
            print("WildlifeCoreChecks: \(checkCount) checks passed")
        } catch {
            FileHandle.standardError.write(Data("WildlifeCoreChecks failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
