import Foundation

public struct PersistedSessions: Codable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var sessions: [SessionRecord]
    public var deletedSessionKeys: [String]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sessions: [SessionRecord],
        deletedSessionKeys: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.deletedSessionKeys = deletedSessionKeys
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessions
        case deletedSessionKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sessions = try container.decode([SessionRecord].self, forKey: .sessions)
        deletedSessionKeys = try container.decodeIfPresent([String].self, forKey: .deletedSessionKeys) ?? []
    }
}

public final class SessionDiskStore {
    private let url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public func load() throws -> [SessionRecord] {
        try loadState().sessions
    }

    public func loadState() throws -> PersistedSessions {
        guard let url else { return PersistedSessions(sessions: []) }
        try SecureLocalFile.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let data: Data
        do {
            data = try SecureLocalFile.readPrivateFile(at: url)
        } catch let error as POSIXError where error.code == .ENOENT {
            return PersistedSessions(sessions: [])
        }
        let state = try JSONDecoder().decode(PersistedSessions.self, from: data)
        guard state.schemaVersion <= PersistedSessions.currentSchemaVersion else {
            return PersistedSessions(sessions: [])
        }
        return normalized(state)
    }

    public func save(_ sessions: [SessionRecord]) throws {
        try save(PersistedSessions(sessions: sessions))
    }

    public func save(_ state: PersistedSessions) throws {
        guard let url else { return }
        try SecureLocalFile.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized(state))
        try SecureLocalFile.writeAtomically(data, to: url)
    }

    private func normalized(_ state: PersistedSessions) -> PersistedSessions {
        var sessions: [SessionRecord] = []
        var indexByKey: [String: Int] = [:]
        for session in state.sessions {
            guard AgentProvider(rawValue: session.providerRaw) != nil,
                  !session.sessionID.isEmpty,
                  session.sessionID.utf8.count <= 1_024 else { continue }
            let key = "\(session.providerRaw):\(session.sessionID)"
            session.stableKey = key
            if let index = indexByKey[key] {
                if session.updatedAt > sessions[index].updatedAt { sessions[index] = session }
            } else {
                indexByKey[key] = sessions.count
                sessions.append(session)
            }
        }

        let validPrefixes = AgentProvider.allCases.map { "\($0.rawValue):" }
        let deletedKeys = Set(state.deletedSessionKeys.filter { key in
            key.utf8.count <= 1_024
                && validPrefixes.contains { key.hasPrefix($0) && key.count > $0.count }
        })
        return PersistedSessions(
            sessions: sessions,
            deletedSessionKeys: deletedKeys.sorted()
        )
    }
}
