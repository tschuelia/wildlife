import Darwin
import Foundation

public struct AgentProcessIdentity: Sendable, Equatable {
    public let pid: Int32
    public let startIdentity: String
    public let tty: String?
}

public enum ProcessInspector {
    private struct Row {
        let pid: Int32
        let parentPID: Int32
        let tty: String
        let startIdentity: String
        let command: String
    }

    public static func captureAgentProcess(
        provider: AgentProvider,
        startingAt pid: Int32 = getppid()
    ) -> AgentProcessIdentity? {
        let rows = snapshot()
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        var cursor = pid
        var fallback: Row?

        for _ in 0..<12 {
            guard let row = byPID[cursor] else { break }
            fallback = fallback ?? row
            if matches(row.command, provider: provider) {
                return AgentProcessIdentity(
                    pid: row.pid,
                    startIdentity: row.startIdentity,
                    tty: normalizedTTY(row.tty)
                )
            }
            if row.parentPID <= 1 || row.parentPID == cursor { break }
            cursor = row.parentPID
        }

        guard let row = fallback else { return nil }
        return AgentProcessIdentity(
            pid: row.pid,
            startIdentity: row.startIdentity,
            tty: normalizedTTY(row.tty)
        )
    }

    public static func isAlive(pid: Int32, startIdentity: String?) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let startIdentity, !startIdentity.isEmpty else { return true }
        return snapshot().first(where: { $0.pid == pid })?.startIdentity == startIdentity
    }

    /// Returns the process and its ancestors, stopping before launchd. The app
    /// uses this to find the GUI application that owns an active terminal.
    public static func ancestorProcessIDs(startingAt pid: Int32, limit: Int = 32) -> [Int32] {
        guard pid > 1, limit > 0 else { return [] }
        let byPID = Dictionary(uniqueKeysWithValues: snapshot().map { ($0.pid, $0) })
        var result: [Int32] = []
        var visited = Set<Int32>()
        var cursor = pid

        for _ in 0..<limit {
            guard cursor > 1,
                  visited.insert(cursor).inserted,
                  let row = byPID[cursor] else { break }
            result.append(row.pid)
            guard row.parentPID > 1, row.parentPID != cursor else { break }
            cursor = row.parentPID
        }
        return result
    }

    private static func snapshot() -> [Row] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,lstart=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n").compactMap(parse)
        } catch {
            return []
        }
    }

    private static func parse(_ line: Substring) -> Row? {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 9,
              let pid = Int32(fields[0]),
              let parent = Int32(fields[1]) else { return nil }
        let start = fields[3...7].joined(separator: " ")
        let command = fields[8...].joined(separator: " ")
        return Row(pid: pid, parentPID: parent, tty: String(fields[2]), startIdentity: start, command: command)
    }

    private static func matches(_ command: String, provider: AgentProvider) -> Bool {
        let value = command.lowercased()
        guard !value.contains("wildlife-hook") else { return false }
        switch provider {
        case .codex:
            return value.contains("/codex ") || value.hasSuffix("/codex") || value.hasPrefix("codex ")
        case .claude:
            return value.contains("/claude ") || value.hasSuffix("/claude") || value.hasPrefix("claude ") || value.contains("/.local/share/claude/")
        }
    }

    private static func normalizedTTY(_ tty: String) -> String? {
        guard tty != "??" && tty != "-" else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }
}
