import Foundation
import WildlifeDomain

package struct GitProjectInspector: Sendable {
    package init() {}

    package func inspect(cwd: String) -> ProjectMetadata? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", cwd, "rev-parse", "--path-format=absolute",
            "--show-toplevel", "--git-common-dir", "--abbrev-ref", "HEAD",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: output, encoding: .utf8) else { return nil }
            return Self.parse(output: text)
        } catch {
            return nil
        }
    }

    package static func parse(output: String) -> ProjectMetadata? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 3 else { return nil }
        let worktree = canonical(lines[0])
        let common = canonical(lines[1])
        let repositoryRoot = URL(fileURLWithPath: common).lastPathComponent == ".git"
            ? URL(fileURLWithPath: common).deletingLastPathComponent().path
            : worktree
        return ProjectMetadata(
            repositoryRoot: canonical(repositoryRoot),
            worktreeRoot: worktree,
            gitCommonDirectory: common,
            branch: lines[2] == "HEAD" ? "Detached HEAD" : lines[2]
        )
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
