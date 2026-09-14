import Foundation

public struct PersistedSessions: Codable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var sessions: [SessionRecord]

    public init(schemaVersion: Int = currentSchemaVersion, sessions: [SessionRecord]) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
    }
}

public final class SessionDiskStore {
    private let url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public func load() throws -> [SessionRecord] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(PersistedSessions.self, from: data)
        guard state.schemaVersion <= PersistedSessions.currentSchemaVersion else { return [] }
        return state.sessions
    }

    public func save(_ sessions: [SessionRecord]) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(PersistedSessions(sessions: sessions))
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
