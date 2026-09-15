import Darwin
import Foundation
import Testing
@testable import WildlifeDomain
@testable import WildlifeInfrastructure

@Suite("Authenticated local transport")
struct LocalSecurityTests {
    @Test("Current-user socket delivers one validated event")
    func transport() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("events.sock")
        let server = LocalEventServer(socketURL: socket)
        let received = ReceivedEvent()
        let delivered = DispatchSemaphore(value: 0)
        try server.start { event in
            received.set(event)
            delivered.signal()
        }
        defer { server.stop() }
        #expect(mode(of: socket) == 0o600)
        #expect(LocalEventTransport.peerUIDIsAllowed(geteuid()))
        #expect(!LocalEventTransport.peerUIDIsAllowed(geteuid() &+ 1))

        let event = AgentEvent(
            sessionID: SessionID(provider: .codex, externalID: "transport"),
            kind: .sessionStart,
            cwd: "/tmp",
            process: AgentProcessIdentity(pid: 42, startIdentity: "start", tty: "/dev/ttys001")
        )
        #expect(LocalEventTransport.send(try JSONEncoder().encode(event), to: socket))
        #expect(delivered.wait(timeout: .now() + 3) == .success)
        #expect(received.value == event)

        server.stop()
        let restarted = AgentEvent(
            sessionID: SessionID(provider: .claude, externalID: "restarted"),
            kind: .sessionStart,
            cwd: "/tmp",
            process: AgentProcessIdentity(pid: 43, startIdentity: "next", tty: "/dev/ttys002")
        )
        try server.start { event in
            received.set(event)
            delivered.signal()
        }
        #expect(LocalEventTransport.send(try JSONEncoder().encode(restarted), to: socket))
        #expect(delivered.wait(timeout: .now() + 3) == .success)
        #expect(received.value == restarted)
    }

    @Test("Unexpected socket paths and spool traversal are rejected")
    func pathSafety() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let occupied = directory.appendingPathComponent("occupied.sock")
        let sentinel = Data("outside".utf8)
        try sentinel.write(to: occupied)
        let server = LocalEventServer(socketURL: occupied)
        #expect(throws: (any Error).self) { try server.start { _ in } }
        #expect(try Data(contentsOf: occupied) == sentinel)
        #expect(RuntimePaths.spoolURL(eventID: "../../outside") == nil)
        #expect(RuntimePaths.spoolURL(eventID: UUID().uuidString) != nil)
    }

    @Test("Removing a Wildlife-owned symlink never changes its target")
    func symlinkRemoval() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link")
        let sentinel = Data("outside".utf8)
        try sentinel.write(to: target)
        #expect(symlink(target.path, link.path) == 0)
        try SecureLocalFile.removeOwnedFileOrLink(at: link)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(try Data(contentsOf: target) == sentinel)
    }

    @Test("Executable validation never strips or repairs permissions")
    func executablePermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("wildlife-hook")
        let payload = Data("executable".utf8)
        try SecureLocalFile.writeAtomically(
            payload,
            to: executable,
            mode: SecureLocalFile.executableFileMode
        )

        #expect(try SecureLocalFile.readOwnedRegularFile(
            at: executable,
            requiredMode: SecureLocalFile.executableFileMode
        ) == payload)
        #expect(mode(of: executable) == 0o700)

        #expect(chmod(executable.path, SecureLocalFile.privateFileMode) == 0)
        #expect(throws: LocalSecurityError.self) {
            _ = try SecureLocalFile.readOwnedRegularFile(
                at: executable,
                requiredMode: SecureLocalFile.executableFileMode
            )
        }
        #expect(mode(of: executable) == 0o600)
    }

    @Test("Process ancestry is finite and excludes launchd")
    func processAncestry() {
        let processID = getpid()
        let ancestors = ProcessInspector.ancestorProcessIDs(startingAt: processID)
        #expect(ancestors.first == processID)
        #expect(Set(ancestors).count == ancestors.count)
        #expect(ProcessInspector.ancestorProcessIDs(startingAt: processID, limit: 1) == [processID])
        #expect(ProcessInspector.ancestorProcessIDs(startingAt: 1).isEmpty)
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/wl-sec-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func mode(of url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }
}

private final class ReceivedEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentEvent?

    var value: AgentEvent? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ event: AgentEvent) {
        lock.lock()
        stored = event
        lock.unlock()
    }
}
