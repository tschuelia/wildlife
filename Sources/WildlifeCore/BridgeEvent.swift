import Foundation

public struct BridgeEvent: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

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

    public static func prepareDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: inboxDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.createDirectory(
            at: installedBridgeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
