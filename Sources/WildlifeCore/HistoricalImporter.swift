import CSQLite
import Foundation

public struct HistoricalImporter: Sendable {
    public init() {}

    public func importSessions(
        codexHome: URL,
        claudeHome: URL,
        since cutoff: Date
    ) -> [ImportedSession] {
        let codex = importCodex(databaseURL: codexHome.appendingPathComponent("state_5.sqlite"), since: cutoff)
        let claude = importClaude(projectsURL: claudeHome.appendingPathComponent("projects"), since: cutoff)
        var unique: [String: ImportedSession] = [:]
        for session in codex + claude {
            if let existing = unique[session.stableKey], existing.updatedAt >= session.updatedAt { continue }
            unique[session.stableKey] = session
        }
        return unique.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func importCodex(databaseURL: URL, since cutoff: Date) -> [ImportedSession] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else { return [] }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT id, title, cwd,
               CASE WHEN created_at_ms > 0 THEN created_at_ms ELSE created_at * 1000 END,
               CASE WHEN recency_at_ms > 0 THEN recency_at_ms
                    WHEN updated_at_ms > 0 THEN updated_at_ms ELSE updated_at * 1000 END
        FROM threads
        WHERE source = 'cli'
          AND (thread_source IS NULL OR thread_source = '' OR thread_source = 'user')
          AND (CASE WHEN recency_at_ms > 0 THEN recency_at_ms
                    WHEN updated_at_ms > 0 THEN updated_at_ms ELSE updated_at * 1000 END) >= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970 * 1_000))

        var result: [ImportedSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, column: 0), !id.isEmpty else { continue }
            let title = text(statement, column: 1) ?? ""
            let cwd = text(statement, column: 2) ?? ""
            let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1_000)
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1_000)
            result.append(ImportedSession(
                provider: .codex,
                sessionID: id,
                title: title,
                cwd: cwd,
                createdAt: created,
                updatedAt: updated
            ))
        }
        return result
    }

    public func importClaude(projectsURL: URL, since cutoff: Date) -> [ImportedSession] {
        guard let projectURLs = try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [ImportedSession] = []
        for projectURL in projectURLs {
            guard (try? projectURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let indexURL = projectURL.appendingPathComponent("sessions-index.json")
            guard let data = try? Data(contentsOf: indexURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = root["entries"] as? [[String: Any]] else { continue }

            for entry in entries {
                guard (entry["isSidechain"] as? Bool) != true,
                      let id = entry["sessionId"] as? String,
                      !id.isEmpty else { continue }
                let updated = parseDate(entry["modified"] ?? entry["fileMtime"])
                guard let updated, updated >= cutoff else { continue }
                let created = parseDate(entry["created"]) ?? updated
                let title = entry["summary"] as? String ?? ""
                let cwd = entry["projectPath"] as? String ?? root["originalPath"] as? String ?? ""
                result.append(ImportedSession(
                    provider: .claude,
                    sessionID: id,
                    title: title,
                    cwd: cwd,
                    createdAt: created,
                    updatedAt: updated
                ))
            }
        }
        return result
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let seconds = value as? Double {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        if let seconds = value as? Int {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? Double(seconds) / 1_000 : Double(seconds))
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
