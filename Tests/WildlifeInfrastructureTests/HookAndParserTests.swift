import Darwin
import Foundation
import Testing
@testable import WildlifeDomain
@testable import WildlifeInfrastructure

@Suite("Provider hook integration")
struct HookAndParserTests {
    @Test("Metadata decoding excludes content-bearing hook fields")
    func metadataOnlyEvent() throws {
        let sentinel = "PRIVATE-CONTENT-SENTINEL"
        let input: [String: Any] = [
            "session_id": "session-allowlist",
            "hook_event_name": "PreToolUse",
            "cwd": "/tmp/project",
            "model": "local-model",
            "tool_name": "Read",
            "prompt": sentinel,
            "tool_input": ["secret": sentinel],
            "transcript_path": "/private/transcript",
        ]
        let event = try AgentEventFactory.decodeHookInput(
            JSONSerialization.data(withJSONObject: input),
            provider: .codex,
            fallbackCWD: "/fallback",
            process: AgentProcessIdentity(pid: 42, startIdentity: "start", tty: "/dev/ttys001")
        )
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(event.sessionID.externalID == "session-allowlist")
        #expect(event.toolName == "Read")
        #expect(!encoded.contains(sentinel))
        #expect(!encoded.contains("prompt"))
        #expect(!encoded.contains("transcript"))
    }

    @Test("Install is lossless, synchronous, idempotent, and reversible")
    func hookLifecycle() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("settings.json")
        let bridge = directory.appendingPathComponent("bin/wildlife-hook")
        let original: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "SessionStart": [[
                    "matcher": "preserve-group",
                    "hooks": [["type": "command", "command": "third-party", "custom": true]],
                ]],
            ],
        ]
        try SecureLocalFile.writeAtomically(JSONSerialization.data(withJSONObject: original), to: config, mode: 0o644)
        #expect(HookConfiguration.installationState(provider: .claude, configURL: config, bridgeURL: bridge) == .notInstalled)
        #expect(mode(of: config) == 0o644)

        let first = try HookConfiguration.install(provider: .claude, configURL: config, bridgeURL: bridge)
        let second = try HookConfiguration.install(provider: .claude, configURL: config, bridgeURL: bridge)
        #expect(first.changed && first.backupURL != nil)
        #expect(!second.changed && second.backupURL == nil)
        #expect(HookConfiguration.installationState(provider: .claude, configURL: config, bridgeURL: bridge) == .installed)
        #expect(mode(of: config) == 0o600)
        #expect(first.backupURL.flatMap(mode) == 0o600)

        let installed = try json(at: config)
        #expect(installed["theme"] as? String == "dark")
        #expect(allOwnedHandlers(in: installed, command: HookConfiguration.hookCommand(bridgeURL: bridge, provider: .claude)) { handler in
            handler["async"] == nil && handler["type"] as? String == "command"
        })
        #expect(containsHandler(in: installed, command: "third-party"))

        let removed = try HookConfiguration.uninstall(provider: .claude, configURL: config, bridgeURL: bridge)
        #expect(removed.changed)
        let uninstalled = try json(at: config)
        #expect(uninstalled["theme"] as? String == "dark")
        #expect(containsHandler(in: uninstalled, command: "third-party"))
        #expect(!containsHandler(in: uninstalled, command: HookConfiguration.hookCommand(bridgeURL: bridge, provider: .claude)))
    }

    @Test("Repair corrects owned handlers without installing absent events")
    func repair() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        let bridge = directory.appendingPathComponent("wildlife-hook")
        let command = HookConfiguration.hookCommand(bridgeURL: bridge, provider: .codex)
        let partial: [String: Any] = [
            "preserve": 7,
            "hooks": [
                "SessionStart": [[
                    "matcher": "keep",
                    "hooks": [
                        ["type": "command", "command": command, "timeout": 99, "async": true, "custom": "keep"],
                        ["type": "command", "command": "third-party"],
                    ],
                ]],
            ],
        ]
        try SecureLocalFile.writeAtomically(JSONSerialization.data(withJSONObject: partial), to: config)
        let result = try HookConfiguration.repairExistingHandlers(provider: .codex, configURL: config, bridgeURL: bridge)
        #expect(result.changed)
        let root = try json(at: config)
        let owned = handlers(in: root).first { $0["command"] as? String == command }
        #expect(owned?["timeout"] as? Int == 2)
        #expect(owned?["async"] == nil)
        #expect(owned?["custom"] as? String == "keep")
        #expect((root["hooks"] as? [String: Any])?["SessionEnd"] == nil)
        #expect(root["preserve"] as? Int == 7)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wildlife-hooks-\(UUID().uuidString)", isDirectory: true)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func handlers(in root: [String: Any]) -> [[String: Any]] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { value in
            (value as? [[String: Any]])?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] } ?? []
        }
    }

    private func containsHandler(in root: [String: Any], command: String) -> Bool {
        handlers(in: root).contains { $0["command"] as? String == command }
    }

    private func allOwnedHandlers(
        in root: [String: Any],
        command: String,
        predicate: ([String: Any]) -> Bool
    ) -> Bool {
        let owned = handlers(in: root).filter { $0["command"] as? String == command }
        return !owned.isEmpty && owned.allSatisfy(predicate)
    }

    private func mode(of url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }
}
