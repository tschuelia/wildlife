import CSQLite
import CoreGraphics
import Foundation
import Testing
@testable import WildlifeDomain
@testable import WildlifeInfrastructure

@Suite("Read-only metadata discovery")
struct HistoryAndProjectTests {
    @Test("Codex history imports interactive CLI roots only")
    func codexHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE threads(
          id TEXT, title TEXT, cwd TEXT, created_at INTEGER, created_at_ms INTEGER,
          updated_at INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER,
          source TEXT, thread_source TEXT
        );
        INSERT INTO threads VALUES('root','Root','/tmp/root',900,0,1000,0,1000000,'cli','user');
        INSERT INTO threads VALUES('sub','Subagent','/tmp/sub',900,0,1000,0,1000000,'cli','subagent');
        INSERT INTO threads VALUES('editor','Editor','/tmp/editor',900,0,1000,0,1000000,'vscode','user');
        INSERT INTO threads VALUES('old','Old','/tmp/old',1,0,2,0,2000,'cli','user');
        """
        #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)

        let result = HistoricalImporter().importCodex(
            databaseURL: databaseURL,
            since: Date(timeIntervalSince1970: 500)
        )
        #expect(result.map(\.id.externalID) == ["root"])
        #expect(result.first?.title == "Root")
    }

    @Test("Claude history decodes metadata and skips sidechains")
    func claudeHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = directory.appendingPathComponent("projects/project", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "originalPath": "/tmp/original",
            "entries": [
                [
                    "sessionId": "root",
                    "summary": "Local summary",
                    "firstPrompt": "must not be used",
                    "created": 900_000,
                    "modified": "1970-01-01T00:16:40.000Z",
                ],
                ["sessionId": "side", "summary": "Sidechain", "modified": 1_000, "isSidechain": true],
                ["sessionId": "old", "summary": "Old", "modified": 2],
            ],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: projects.appendingPathComponent("sessions-index.json"))

        let result = HistoricalImporter().importClaude(
            projectsURL: directory.appendingPathComponent("projects"),
            since: Date(timeIntervalSince1970: 500)
        )
        #expect(result.count == 1)
        #expect(result.first?.id.externalID == "root")
        #expect(result.first?.title == "Local summary")
        #expect(result.first?.cwd == "/tmp/original")
    }

    @Test("Git worktree metadata parsing is canonical and strict")
    func gitParsing() {
        let parsed = GitProjectInspector.parse(output: "/tmp/repository-worktree\n/tmp/repository/.git\nfeature/activity\n")
        #expect(parsed?.repositoryRoot == "/tmp/repository")
        #expect(parsed?.worktreeRoot == "/tmp/repository-worktree")
        #expect(parsed?.branch == "feature/activity")
        #expect(GitProjectInspector.parse(output: "missing\nlines\n") == nil)
    }

    @Test("Notch geometry remains attached and display-bounded")
    func notchGeometry() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        ))
        #expect(geometry.notchFrame == CGRect(x: 663, y: 950, width: 185, height: 32))
        #expect(geometry.compactFrame == CGRect(x: 633, y: 950, width: 245, height: 32))
        #expect(geometry.expandedFrame(width: 400, height: 300).maxY == geometry.screenFrame.maxY)
        #expect(NotchGeometry(
            screenFrame: geometry.screenFrame,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        ) == nil)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wildlife-history-\(UUID().uuidString)", isDirectory: true)
    }
}
