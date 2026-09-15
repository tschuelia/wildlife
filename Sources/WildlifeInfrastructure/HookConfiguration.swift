import Foundation
import WildlifeDomain

package enum HookConfigurationError: LocalizedError {
    case malformedRoot(URL)
    case missingBridgeBinary

    package var errorDescription: String? {
        switch self {
        case .malformedRoot(let url): "The configuration at \(url.path) is not a JSON object. It was not changed."
        case .missingBridgeBinary: "The wildlife-hook binary could not be found in this build."
        }
    }
}

package struct HookInstallResult: Sendable {
    package let changed: Bool
    package let backupURL: URL?
}

package enum HookInstallationState: String, Sendable {
    case notInstalled
    case needsRepair
    case installed
}

private enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

package enum HookConfiguration {
    private enum Mutation: Equatable { case install, repair, uninstall }

    package static func install(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL,
        now: Date = Date()
    ) throws -> HookInstallResult {
        try mutate(.install, provider: provider, configURL: configURL, bridgeURL: bridgeURL, now: now)
    }

    package static func repairExistingHandlers(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL,
        now: Date = Date()
    ) throws -> HookInstallResult {
        try mutate(.repair, provider: provider, configURL: configURL, bridgeURL: bridgeURL, now: now)
    }

    package static func uninstall(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL,
        now: Date = Date()
    ) throws -> HookInstallResult {
        try mutate(.uninstall, provider: provider, configURL: configURL, bridgeURL: bridgeURL, now: now)
    }

    package static func installationState(
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL
    ) -> HookInstallationState {
        guard let data = try? SecureLocalFile.readOwnedRegularFile(at: configURL, maximumSize: 4 * 1_024 * 1_024),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data).object,
              let hooks = root["hooks"]?.object else { return .notInstalled }
        let command = hookCommand(bridgeURL: bridgeURL, provider: provider)
        let installed = AgentEvent.kinds(for: provider).allSatisfy { kind in
            handlers(in: hooks[kind.rawValue]).contains { handler in
                handler["command"]?.string == command && handlerIsCurrent(handler, event: kind, command: command)
            }
        }
        if installed { return .installed }
        let ownsHandler = hooks.values.contains { value in
            handlers(in: value).contains { $0["command"]?.string == command }
        }
        return ownsHandler ? .needsRepair : .notInstalled
    }

    package static func hookCommand(bridgeURL: URL, provider: AgentProvider) -> String {
        "\(ResumeCommandTemplate.shellQuote(bridgeURL.path)) \(provider.rawValue)"
    }

    private static func mutate(
        _ mutation: Mutation,
        provider: AgentProvider,
        configURL: URL,
        bridgeURL: URL,
        now: Date
    ) throws -> HookInstallResult {
        var originalData: Data?
        var root: [String: JSONValue]
        do {
            let data = try SecureLocalFile.readOwnedRegularFile(at: configURL, maximumSize: 4 * 1_024 * 1_024)
            originalData = data
            guard let object = try JSONDecoder().decode(JSONValue.self, from: data).object else {
                throw HookConfigurationError.malformedRoot(configURL)
            }
            root = object
        } catch let error as POSIXError where error.code == .ENOENT {
            guard mutation == .install else { return HookInstallResult(changed: false, backupURL: nil) }
            originalData = nil
            root = [:]
        } catch is DecodingError {
            throw HookConfigurationError.malformedRoot(configURL)
        }

        let command = hookCommand(bridgeURL: bridgeURL, provider: provider)
        var hooks = root["hooks"]?.object ?? [:]
        let changed: Bool
        switch mutation {
        case .install, .repair:
            changed = reconcile(
                hooks: &hooks,
                provider: provider,
                command: command,
                addMissing: mutation == .install
            )
        case .uninstall:
            changed = removeOwnedHandlers(hooks: &hooks, command: command)
        }
        guard changed else { return HookInstallResult(changed: false, backupURL: nil) }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = .object(hooks) }
        let backup = try backupIfNeeded(originalData, configURL: configURL, now: now)
        try write(.object(root), to: configURL)
        return HookInstallResult(changed: true, backupURL: backup)
    }

    private static func reconcile(
        hooks: inout [String: JSONValue],
        provider: AgentProvider,
        command: String,
        addMissing: Bool
    ) -> Bool {
        var changed = false
        for event in AgentEvent.kinds(for: provider) {
            var groups = hooks[event.rawValue]?.array ?? []
            var found = false
            for groupIndex in groups.indices {
                guard var group = groups[groupIndex].object,
                      var entries = group["hooks"]?.array else { continue }
                for handlerIndex in entries.indices {
                    guard let handler = entries[handlerIndex].object,
                          handler["command"]?.string == command else { continue }
                    found = true
                    let desired = desiredHandler(event: event, command: command)
                    var repaired = handler
                    repaired["type"] = desired["type"]
                    repaired["command"] = desired["command"]
                    repaired["timeout"] = desired["timeout"]
                    repaired.removeValue(forKey: "async")
                    if handler != repaired {
                        entries[handlerIndex] = .object(repaired)
                        changed = true
                    }
                }
                group["hooks"] = .array(entries)
                groups[groupIndex] = .object(group)
            }
            if !found, addMissing {
                groups.append(.object(["hooks": .array([.object(desiredHandler(event: event, command: command))])]))
                changed = true
            }
            if found || addMissing { hooks[event.rawValue] = .array(groups) }
        }
        return changed
    }

    private static func removeOwnedHandlers(hooks: inout [String: JSONValue], command: String) -> Bool {
        var changed = false
        for event in Array(hooks.keys) {
            guard let groups = hooks[event]?.array else { continue }
            let cleaned = groups.compactMap { value -> JSONValue? in
                guard var group = value.object, let entries = group["hooks"]?.array else { return value }
                let remaining = entries.filter { $0.object?["command"]?.string != command }
                if remaining.count != entries.count { changed = true }
                guard !remaining.isEmpty else { return nil }
                group["hooks"] = .array(remaining)
                return .object(group)
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = .array(cleaned) }
        }
        return changed
    }

    private static func handlers(in value: JSONValue?) -> [[String: JSONValue]] {
        value?.array?.flatMap { group in
            group.object?["hooks"]?.array?.compactMap(\.object) ?? []
        } ?? []
    }

    private static func desiredHandler(event: AgentEvent.Kind, command: String) -> [String: JSONValue] {
        [
            "type": .string("command"),
            "command": .string(command),
            "timeout": .number(event == .sessionEnd ? 3 : 2),
        ]
    }

    private static func handlerIsCurrent(
        _ handler: [String: JSONValue],
        event: AgentEvent.Kind,
        command: String
    ) -> Bool {
        let desired = desiredHandler(event: event, command: command)
        return handler["type"] == desired["type"]
            && handler["command"] == desired["command"]
            && handler["timeout"] == desired["timeout"]
            && handler["async"] == nil
    }

    private static func backupIfNeeded(_ data: Data?, configURL: URL, now: Date) throws -> URL? {
        guard let data else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let suffix = UUID().uuidString.prefix(8)
        let backup = configURL.deletingLastPathComponent()
            .appendingPathComponent("\(configURL.lastPathComponent).wildlife-backup-\(formatter.string(from: now))-\(suffix)")
        try SecureLocalFile.writeAtomically(data, to: backup)
        return backup
    }

    private static func write(_ root: JSONValue, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try SecureLocalFile.writeAtomically(try encoder.encode(root), to: url)
    }
}
