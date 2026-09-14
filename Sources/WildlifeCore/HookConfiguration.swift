import Foundation

public enum HookConfigurationError: LocalizedError {
    case malformedRoot(URL)
    case missingBridgeBinary

    public var errorDescription: String? {
        switch self {
        case .malformedRoot(let url):
            "The configuration at \(url.path) is not a JSON object. It was not changed."
        case .missingBridgeBinary:
            "The wildlife-hook binary could not be found in this build."
        }
    }
}

public struct HookInstallResult: Sendable {
    public let changed: Bool
    public let backupURL: URL?
}

public enum HookInstallationState: String, Sendable {
    case notInstalled
    case needsRepair
    case installed
}

public enum HookConfiguration {
    public static let codexEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
        "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact",
        "SubagentStart", "SubagentStop", "Stop", "Interrupt",
    ]

    public static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
        "PermissionRequest", "PermissionDenied", "PostToolUse",
        "PostToolUseFailure", "PreCompact", "PostCompact", "SubagentStart",
        "SubagentStop", "Notification", "Stop", "StopFailure",
    ]

    public static func install(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL,
        now: Date = Date()
    ) throws -> HookInstallResult {
        let manager = FileManager.default
        var root: [String: Any]
        let originalData: Data?
        if manager.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            originalData = data
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw HookConfigurationError.malformedRoot(configURL)
            }
            root = dictionary
        } else {
            originalData = nil
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = hookCommand(bridgeURL: bridgeURL, provider: provider)
        let events = provider == .codex ? codexEvents : claudeEvents
        var changed = false

        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let desired = desiredHandler(provider: provider, event: event, command: command)
            var found = false

            for groupIndex in groups.indices {
                guard var handlers = groups[groupIndex]["hooks"] as? [[String: Any]] else { continue }
                var groupChanged = false
                for handlerIndex in handlers.indices where handlers[handlerIndex]["command"] as? String == command {
                    found = true
                    let reconciled = reconcile(existing: handlers[handlerIndex], with: desired)
                    if !NSDictionary(dictionary: handlers[handlerIndex]).isEqual(to: reconciled) {
                        handlers[handlerIndex] = reconciled
                        groupChanged = true
                    }
                }
                if groupChanged {
                    groups[groupIndex]["hooks"] = handlers
                    changed = true
                }
            }

            if !found {
                groups.append(["hooks": [desired]])
                changed = true
            }
            hooks[event] = groups
        }

        guard changed else { return HookInstallResult(changed: false, backupURL: nil) }
        root["hooks"] = hooks
        let backup = try backupIfNeeded(data: originalData, configURL: configURL, now: now)
        try write(root, to: configURL)
        return HookInstallResult(changed: true, backupURL: backup)
    }

    /// Updates handler options only for Wildlife commands already present in a
    /// provider's configuration. Unlike `install`, this never adds missing
    /// events or creates a new integration.
    public static func repairExistingHandlers(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL,
        now: Date = Date()
    ) throws -> HookInstallResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: configURL.path) else {
            return HookInstallResult(changed: false, backupURL: nil)
        }

        let originalData = try Data(contentsOf: configURL)
        let object = try JSONSerialization.jsonObject(with: originalData)
        guard var root = object as? [String: Any] else {
            throw HookConfigurationError.malformedRoot(configURL)
        }
        guard var hooks = root["hooks"] as? [String: Any] else {
            return HookInstallResult(changed: false, backupURL: nil)
        }

        let command = hookCommand(bridgeURL: bridgeURL, provider: provider)
        let events = provider == .codex ? codexEvents : claudeEvents
        var changed = false

        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            let desired = desiredHandler(provider: provider, event: event, command: command)

            for groupIndex in groups.indices {
                guard var handlers = groups[groupIndex]["hooks"] as? [[String: Any]] else { continue }
                var groupChanged = false
                for handlerIndex in handlers.indices where handlers[handlerIndex]["command"] as? String == command {
                    let reconciled = reconcile(existing: handlers[handlerIndex], with: desired)
                    if !NSDictionary(dictionary: handlers[handlerIndex]).isEqual(to: reconciled) {
                        handlers[handlerIndex] = reconciled
                        groupChanged = true
                    }
                }
                if groupChanged {
                    groups[groupIndex]["hooks"] = handlers
                    changed = true
                }
            }
            hooks[event] = groups
        }

        guard changed else { return HookInstallResult(changed: false, backupURL: nil) }
        root["hooks"] = hooks
        let backup = try backupIfNeeded(data: originalData, configURL: configURL, now: now)
        try write(root, to: configURL)
        return HookInstallResult(changed: true, backupURL: backup)
    }

    public static func uninstall(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL,
        now: Date = Date()
    ) throws -> HookInstallResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: configURL.path) else {
            return HookInstallResult(changed: false, backupURL: nil)
        }
        let originalData = try Data(contentsOf: configURL)
        let object = try JSONSerialization.jsonObject(with: originalData)
        guard var root = object as? [String: Any] else {
            throw HookConfigurationError.malformedRoot(configURL)
        }
        guard var hooks = root["hooks"] as? [String: Any] else {
            return HookInstallResult(changed: false, backupURL: nil)
        }

        let command = hookCommand(bridgeURL: bridgeURL, provider: provider)
        var changed = false
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = groups.compactMap { group -> [String: Any]? in
                var mutable = group
                guard let handlers = mutable["hooks"] as? [[String: Any]] else { return mutable }
                let remaining = handlers.filter { ($0["command"] as? String) != command }
                if remaining.count != handlers.count { changed = true }
                guard !remaining.isEmpty else { return nil }
                mutable["hooks"] = remaining
                return mutable
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }

        guard changed else { return HookInstallResult(changed: false, backupURL: nil) }
        root["hooks"] = hooks
        let backup = try backupIfNeeded(data: originalData, configURL: configURL, now: now)
        try write(root, to: configURL)
        return HookInstallResult(changed: true, backupURL: backup)
    }

    public static func isInstalled(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL
    ) -> Bool {
        installationState(provider: provider, configURL: configURL, bridgeURL: bridgeURL) == .installed
    }

    public static func installationState(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL
    ) -> HookInstallationState {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        let command = hookCommand(bridgeURL: bridgeURL, provider: provider)
        let required = provider == .codex ? codexEvents : claudeEvents
        let installed = required.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            let desired = desiredHandler(provider: provider, event: event, command: command)
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains {
                    ($0["command"] as? String) == command && handlerIsCurrent($0, desired: desired)
                }
            }
        }
        if installed { return .installed }

        let hasWildlifeHandler = hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return contains(command: command, in: groups)
        }
        return hasWildlifeHandler ? .needsRepair : .notInstalled
    }

    public static func hookCommand(bridgeURL: URL, provider: AgentProvider) -> String {
        "\(ResumeCommandTemplate.shellQuote(bridgeURL.path)) \(provider.rawValue)"
    }

    private static func contains(command: String, in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
            return handlers.contains { ($0["command"] as? String) == command }
        }
    }

    private static func desiredHandler(
        provider: AgentProvider,
        event: String,
        command: String
    ) -> [String: Any] {
        var handler: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": event == "SessionEnd" ? 3 : 2,
        ]
        // The installed Codex runtime warns and skips command hooks carrying
        // `async`. Claude supports it, so retain asynchronous delivery there
        // except at shutdown.
        if provider == .claude && event != "SessionEnd" {
            handler["async"] = true
        }
        return handler
    }

    private static func reconcile(existing: [String: Any], with desired: [String: Any]) -> [String: Any] {
        var reconciled = existing
        reconciled["type"] = desired["type"]
        reconciled["command"] = desired["command"]
        reconciled["timeout"] = desired["timeout"]
        if let asynchronous = desired["async"] {
            reconciled["async"] = asynchronous
        } else {
            reconciled.removeValue(forKey: "async")
        }
        return reconciled
    }

    private static func handlerIsCurrent(_ handler: [String: Any], desired: [String: Any]) -> Bool {
        guard handler["type"] as? String == desired["type"] as? String,
              handler["command"] as? String == desired["command"] as? String,
              number(handler["timeout"]) == number(desired["timeout"]) else {
            return false
        }
        if let desiredAsync = desired["async"] as? Bool {
            return handler["async"] as? Bool == desiredAsync
        }
        return handler["async"] == nil
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func backupIfNeeded(data: Data?, configURL: URL, now: Date) throws -> URL? {
        guard let data else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = configURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(configURL.lastPathComponent).wildlife-backup-\(formatter.string(from: now))")
        try data.write(to: backup, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    private static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
