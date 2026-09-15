import CSQLite
import Darwin
import Foundation
import Testing
@testable import WildlifeDomain
@testable import WildlifeInfrastructure

@Suite("Session database")
struct SessionDatabaseTests {
    @Test("Normalized library state round trips transactionally")
    func roundTrip() async throws {
        let database = try SessionDatabase(url: nil)
        let id = SessionID(provider: .claude, externalID: "stored")
        var session = Session(
            id: id,
            sourceTitle: "Stored session",
            emoji: .custom("🦉"),
            cwd: "/tmp/project",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lifecycle: .completed(EndedSessionState(endedAt: Date(timeIntervalSince1970: 20)))
        )
        session.tags = ["backend", "urgent"]
        session.notes = "Local notes"
        session.activities = [SessionActivity(
            id: UUID().uuidString,
            timestamp: session.updatedAt,
            event: .sessionEnd,
            status: .ended,
            toolName: nil,
            endReason: "logout",
            notificationType: nil,
            subagentCount: 0
        )]
        let previous = SessionCollection()
        let next = SessionCollection(sessions: [session])
        try await database.apply(previous: previous, next: next)
        let view = SavedSessionView(name: "Urgent", filter: SessionFilter(tags: ["urgent"]))
        try await database.saveViews([view])

        let stored = try await database.load()
        #expect(stored.collection[id] == session)
        #expect(stored.savedViews == [view])

        var updated = stored.collection
        updated.update(id) { value in
            value.notes = "Updated without replacing normalized children"
            value.tags.append("local")
        }
        try await database.apply(previous: stored.collection, next: updated)
        let afterUpdate = try await database.load()
        #expect(afterUpdate.collection[id]?.notes == "Updated without replacing normalized children")
        #expect(afterUpdate.collection[id]?.tags == ["backend", "urgent", "local"])
        #expect(afterUpdate.collection[id]?.activities == session.activities)

        var deleted = afterUpdate.collection
        deleted.delete(id)
        try await database.apply(previous: afterUpdate.collection, next: deleted)
        let afterDelete = try await database.load()
        #expect(afterDelete.collection[id] == nil)
        #expect(afterDelete.collection.tombstones == [id])
    }

    @Test("Database and parent directory are private")
    func permissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Library/Wildlife.sqlite3")
        let database = try SessionDatabase(url: url)
        _ = try await database.load()

        #expect(mode(of: url) == 0o600)
        #expect(mode(of: url.deletingLastPathComponent()) == 0o700)
    }

    @Test("A future schema is rejected without alteration")
    func unsupportedSchema() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("future.sqlite3")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        guard let handle else { return }
        #expect(sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        #expect(throws: SessionDatabaseError.self) {
            _ = try SessionDatabase(url: url)
        }
        var reopened: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &reopened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        guard let reopened else { return }
        defer { sqlite3_close(reopened) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(reopened, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        guard let statement else { return }
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 99)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wildlife-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func mode(of url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }
}
