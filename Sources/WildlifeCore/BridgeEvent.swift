import Foundation

public struct BridgeEvent: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    private static let maximumSessionIDBytes = 1_024
    private static let maximumPathBytes = 4_096
    private static let maximumMetadataBytes = 1_024

    public let schemaVersion: Int
    public let eventID: String
    public let provider: AgentProvider
    public let sessionID: String
    public let lifecycleEvent: String
    public let timestamp: Date
    public let cwd: String
    public let processID: Int32?
    public let processStartIdentity: String?
    public let tty: String?
    public let model: String?
    public let toolName: String?
    public let startSource: String?
    public let endReason: String?
    public let notificationType: String?

    public init(
        schemaVersion: Int = BridgeEvent.currentSchemaVersion,
        eventID: String = UUID().uuidString,
        provider: AgentProvider,
        sessionID: String,
        lifecycleEvent: String,
        timestamp: Date = Date(),
        cwd: String,
        processID: Int32? = nil,
        processStartIdentity: String? = nil,
        tty: String? = nil,
        model: String? = nil,
        toolName: String? = nil,
        startSource: String? = nil,
        endReason: String? = nil,
        notificationType: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.provider = provider
        self.sessionID = sessionID
        self.lifecycleEvent = lifecycleEvent
        self.timestamp = timestamp
        self.cwd = cwd
        self.processID = processID
        self.processStartIdentity = processStartIdentity
        self.tty = tty
        self.model = model
        self.toolName = toolName
        self.startSource = startSource
        self.endReason = endReason
        self.notificationType = notificationType
    }

    package var stableKey: String { "\(provider.rawValue):\(sessionID)" }

    package var isValidForTransport: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              UUID(uuidString: eventID) != nil,
              !sessionID.isEmpty,
              sessionID.utf8.count <= Self.maximumSessionIDBytes,
              cwd.utf8.count <= Self.maximumPathBytes,
              supportedLifecycleEvents.contains(lifecycleEvent),
              processID.map({ $0 > 1 }) ?? true else { return false }
        return [processStartIdentity, tty, model, toolName, startSource, endReason, notificationType]
            .compactMap { $0 }
            .allSatisfy { $0.utf8.count <= Self.maximumMetadataBytes }
    }

    private var supportedLifecycleEvents: Set<String> {
        Set(provider == .codex ? HookConfiguration.codexEvents : HookConfiguration.claudeEvents)
    }
}

public enum RuntimePaths {
    public static var applicationSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WILDLIFE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wildlife", isDirectory: true)
    }

    public static var inboxDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Inbox", isDirectory: true)
    }

    public static var installedBridgeURL: URL {
        applicationSupportDirectory.appendingPathComponent("bin/wildlife-hook")
    }

    public static var socketURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wildlife-\(getuid()).sock")
    }

    package static func spoolURL(eventID: String) -> URL? {
        guard UUID(uuidString: eventID) != nil else { return nil }
        return inboxDirectory.appendingPathComponent("\(eventID).json", isDirectory: false)
    }

    public static func prepareDirectories() throws {
        try SecureLocalFile.ensurePrivateDirectory(at: applicationSupportDirectory)
        try SecureLocalFile.ensurePrivateDirectory(at: inboxDirectory)
        try SecureLocalFile.ensurePrivateDirectory(at: installedBridgeURL.deletingLastPathComponent())
    }
}
