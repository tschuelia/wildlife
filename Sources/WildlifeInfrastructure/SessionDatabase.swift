import CSQLite
import Darwin
import Foundation
import WildlifeDomain

package struct StoredLibrary: Sendable {
    package var collection: SessionCollection
    package var savedViews: [SavedSessionView]
}

package enum SessionDatabaseError: LocalizedError {
    case open(String)
    case statement(String)
    case corruptRecord(String)
    case unsupportedSchema(Int32)

    package var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open Wildlife's database: \(message)"
        case .statement(let message): "Wildlife's database operation failed: \(message)"
        case .corruptRecord(let message): "Wildlife's database contains an invalid record: \(message)"
        case .unsupportedSchema(let version): "This Wildlife database uses unsupported schema \(version)."
        }
    }
}

package actor SessionDatabase {
    private static let schemaVersion: Int32 = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private nonisolated(unsafe) var database: OpaquePointer?

    package init(url: URL?) throws {
        let path: String
        if let url {
            try SecureLocalFile.ensurePrivateDirectory(at: url.deletingLastPathComponent())
            path = url.path
        } else {
            path = ":memory:"
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw SessionDatabaseError.open(message)
        }
        database = handle
        if let url, chmod(url.path, SecureLocalFile.privateFileMode) != 0 {
            sqlite3_close(handle)
            database = nil
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try Self.execute("PRAGMA foreign_keys = ON", on: handle)
            try Self.execute("PRAGMA busy_timeout = 3000", on: handle)
            if url != nil { try Self.execute("PRAGMA journal_mode = WAL", on: handle) }
            try Self.prepareSchema(on: handle)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    package func load() throws -> StoredLibrary {
        guard let database else { throw SessionDatabaseError.open("database is closed") }
        var sessions: [SessionID: Session] = [:]
        try query("SELECT id, core FROM sessions", on: database) { statement in
            guard let id = Self.text(statement, 0), let data = Self.data(statement, 1) else {
                throw SessionDatabaseError.corruptRecord("session row is incomplete")
            }
            var session = try JSONDecoder().decode(Session.self, from: data)
            guard session.id.description == id else {
                throw SessionDatabaseError.corruptRecord("session key does not match its payload")
            }
            session.tags = []
            session.activities = []
            sessions[session.id] = session
        }
        let sessionIDsByKey = Dictionary(uniqueKeysWithValues: sessions.keys.map { ($0.description, $0) })

        try query("SELECT session_id, tag FROM session_tags ORDER BY position", on: database) { statement in
            guard let key = Self.text(statement, 0), let tag = Self.text(statement, 1),
                  let id = sessionIDsByKey[key], var session = sessions[id] else {
                throw SessionDatabaseError.corruptRecord("tag refers to an unknown session")
            }
            session.tags.append(tag)
            sessions[id] = session
        }
        try query("SELECT session_id, payload FROM activities ORDER BY timestamp, event_id", on: database) { statement in
            guard let key = Self.text(statement, 0), let data = Self.data(statement, 1),
                  let id = sessionIDsByKey[key], var session = sessions[id] else {
                throw SessionDatabaseError.corruptRecord("activity refers to an unknown session")
            }
            session.activities.append(try JSONDecoder().decode(SessionActivity.self, from: data))
            sessions[id] = session
        }

        var tombstones = Set<SessionID>()
        try query("SELECT provider, external_id FROM tombstones", on: database) { statement in
            guard let providerRaw = Self.text(statement, 0), let provider = AgentProvider(rawValue: providerRaw),
                  let externalID = Self.text(statement, 1), !externalID.isEmpty else {
                throw SessionDatabaseError.corruptRecord("tombstone has an invalid identity")
            }
            tombstones.insert(SessionID(provider: provider, externalID: externalID))
        }

        var savedViews: [SavedSessionView] = []
        try query("SELECT payload FROM saved_views ORDER BY position", on: database) { statement in
            guard let data = Self.data(statement, 0) else { return }
            savedViews.append(try JSONDecoder().decode(SavedSessionView.self, from: data))
        }
        return StoredLibrary(
            collection: SessionCollection(sessions: Array(sessions.values), tombstones: tombstones),
            savedViews: savedViews
        )
    }

    package func apply(previous: SessionCollection, next: SessionCollection) throws {
        guard let database else { throw SessionDatabaseError.open("database is closed") }
        try transaction(on: database) {
            let removed = Set(previous.sessions.keys).subtracting(next.sessions.keys)
            for id in removed { try deleteSession(id, on: database) }
            for (id, session) in next.sessions where previous.sessions[id] != session {
                let old = previous.sessions[id]
                try upsertCore(session, on: database)
                if old?.tags != session.tags {
                    try replaceTags(for: session, on: database)
                }
                if old?.activities != session.activities {
                    try synchronizeActivities(previous: old?.activities ?? [], next: session.activities, sessionID: id, on: database)
                }
            }
            for id in next.tombstones.subtracting(previous.tombstones) {
                try insertTombstone(id, on: database)
            }
            for id in previous.tombstones.subtracting(next.tombstones) {
                try removeTombstone(id, on: database)
            }
        }
    }

    package func saveViews(_ views: [SavedSessionView]) throws {
        guard let database else { throw SessionDatabaseError.open("database is closed") }
        try transaction(on: database) {
            try Self.execute("DELETE FROM saved_views", on: database)
            for (position, view) in views.enumerated() {
                let data = try JSONEncoder().encode(view)
                try withStatement("INSERT INTO saved_views(id, position, payload) VALUES(?, ?, ?)", on: database) { statement in
                    Self.bind(view.id, to: statement, at: 1)
                    sqlite3_bind_int64(statement, 2, Int64(position))
                    Self.bind(data, to: statement, at: 3)
                    try Self.stepDone(statement, on: database)
                }
            }
        }
    }

    private func upsertCore(_ session: Session, on database: OpaquePointer) throws {
        var core = session
        core.tags = []
        core.activities = []
        let coreData = try JSONEncoder().encode(core)
        try withStatement(
            "INSERT INTO sessions(id, provider, external_id, updated_at, core) VALUES(?, ?, ?, ?, ?) " +
            "ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, external_id=excluded.external_id, " +
            "updated_at=excluded.updated_at, core=excluded.core",
            on: database
        ) { statement in
            Self.bind(session.id.description, to: statement, at: 1)
            Self.bind(session.provider.rawValue, to: statement, at: 2)
            Self.bind(session.sessionID, to: statement, at: 3)
            sqlite3_bind_double(statement, 4, session.updatedAt.timeIntervalSince1970)
            Self.bind(coreData, to: statement, at: 5)
            try Self.stepDone(statement, on: database)
        }

    }

    private func replaceTags(for session: Session, on database: OpaquePointer) throws {
        try withStatement("DELETE FROM session_tags WHERE session_id = ?", on: database) { statement in
            Self.bind(session.id.description, to: statement, at: 1)
            try Self.stepDone(statement, on: database)
        }
        for (position, tag) in session.tags.enumerated() {
            try withStatement("INSERT INTO session_tags(session_id, tag, position) VALUES(?, ?, ?)", on: database) { statement in
                Self.bind(session.id.description, to: statement, at: 1)
                Self.bind(tag, to: statement, at: 2)
                sqlite3_bind_int64(statement, 3, Int64(position))
                try Self.stepDone(statement, on: database)
            }
        }
    }

    private func synchronizeActivities(
        previous: [SessionActivity],
        next: [SessionActivity],
        sessionID: SessionID,
        on database: OpaquePointer
    ) throws {
        let retained = Array(next.suffix(SessionActivityRecorder.detailLimit))
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let retainedIDs = Set(retained.map(\.id))
        for id in oldByID.keys where !retainedIDs.contains(id) {
            try withStatement("DELETE FROM activities WHERE session_id = ? AND event_id = ?", on: database) { statement in
                Self.bind(sessionID.description, to: statement, at: 1)
                Self.bind(id, to: statement, at: 2)
                try Self.stepDone(statement, on: database)
            }
        }
        for activity in retained where oldByID[activity.id] != activity {
            let data = try JSONEncoder().encode(activity)
            try withStatement(
                "INSERT OR REPLACE INTO activities(session_id, event_id, timestamp, payload) VALUES(?, ?, ?, ?)",
                on: database
            ) { statement in
                Self.bind(sessionID.description, to: statement, at: 1)
                Self.bind(activity.id, to: statement, at: 2)
                sqlite3_bind_double(statement, 3, activity.timestamp.timeIntervalSince1970)
                Self.bind(data, to: statement, at: 4)
                try Self.stepDone(statement, on: database)
            }
        }
    }

    private func deleteSession(_ id: SessionID, on database: OpaquePointer) throws {
        try withStatement("DELETE FROM sessions WHERE id = ?", on: database) { statement in
            Self.bind(id.description, to: statement, at: 1)
            try Self.stepDone(statement, on: database)
        }
    }

    private func insertTombstone(_ id: SessionID, on database: OpaquePointer) throws {
        try withStatement("INSERT OR REPLACE INTO tombstones(id, provider, external_id) VALUES(?, ?, ?)", on: database) { statement in
            Self.bind(id.description, to: statement, at: 1)
            Self.bind(id.provider.rawValue, to: statement, at: 2)
            Self.bind(id.externalID, to: statement, at: 3)
            try Self.stepDone(statement, on: database)
        }
    }

    private func removeTombstone(_ id: SessionID, on database: OpaquePointer) throws {
        try withStatement("DELETE FROM tombstones WHERE id = ?", on: database) { statement in
            Self.bind(id.description, to: statement, at: 1)
            try Self.stepDone(statement, on: database)
        }
    }

    private static func prepareSchema(on database: OpaquePointer) throws {
        let version = schemaVersion(on: database)
        guard version <= schemaVersion else { throw SessionDatabaseError.unsupportedSchema(version) }
        guard version == 0 else { return }
        try execute("BEGIN IMMEDIATE", on: database)
        do {
            try execute("""
                CREATE TABLE sessions(
                    id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_id TEXT NOT NULL,
                    updated_at REAL NOT NULL, core BLOB NOT NULL
                );
                CREATE TABLE session_tags(
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    tag TEXT NOT NULL, position INTEGER NOT NULL,
                    PRIMARY KEY(session_id, tag)
                );
                CREATE TABLE activities(
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    event_id TEXT NOT NULL, timestamp REAL NOT NULL, payload BLOB NOT NULL,
                    PRIMARY KEY(session_id, event_id)
                );
                CREATE INDEX activities_by_session_time ON activities(session_id, timestamp);
                CREATE TABLE tombstones(
                    id TEXT PRIMARY KEY, provider TEXT NOT NULL, external_id TEXT NOT NULL
                );
                CREATE TABLE saved_views(
                    id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload BLOB NOT NULL
                );
                PRAGMA user_version = 1;
                """, on: database)
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    private static func schemaVersion(on database: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    private func transaction(on database: OpaquePointer, body: () throws -> Void) throws {
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            try body()
            try Self.execute("COMMIT", on: database)
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    private func query(_ sql: String, on database: OpaquePointer, row: (OpaquePointer) throws -> Void) throws {
        try withStatement(sql, on: database) { statement in
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: try row(statement)
                case SQLITE_DONE: return
                default: throw SessionDatabaseError.statement(String(cString: sqlite3_errmsg(database)))
                }
            }
        }
    }

    private func withStatement<T>(
        _ sql: String,
        on database: OpaquePointer,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SessionDatabaseError.statement(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SessionDatabaseError.statement(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func stepDone(_ statement: OpaquePointer, on database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionDatabaseError.statement(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) {
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), transient)
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
