import Darwin
import Foundation
import WildlifeCore

private func value(_ key: String, in input: [String: Any]) -> String? {
    guard let value = input[key] as? String, !value.isEmpty else { return nil }
    return value
}

private func socketAddress(path: String) -> (sockaddr_un, socklen_t)? {
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    address.sun_len = UInt8(length)
    return (address, length)
}

private func sendToRunningApp(_ data: Data) {
    guard let socketAddress = socketAddress(path: RuntimePaths.socketURL.path) else { return }
    var address = socketAddress.0
    let length = socketAddress.1
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, length)
        }
    }
    guard connected == 0 else { return }
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
            if count <= 0 { break }
            sent += count
        }
    }
    shutdown(descriptor, SHUT_WR)
}

private func spool(_ data: Data, eventID: String) {
    do {
        try RuntimePaths.prepareDirectories()
        let destination = RuntimePaths.inboxDirectory.appendingPathComponent("\(eventID).json")
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch {
        // Hooks are deliberately fail-open. An unavailable inbox must never affect the agent.
    }
}

guard CommandLine.arguments.count >= 2,
      let provider = AgentProvider(rawValue: CommandLine.arguments[1]),
      let inputData = try? FileHandle.standardInput.readToEnd(),
      let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
      let sessionID = value("session_id", in: input),
      let eventName = value("hook_event_name", in: input) else {
    exit(0)
}

let process = ProcessInspector.captureAgentProcess(provider: provider)
let event = BridgeEvent(
    provider: provider,
    sessionID: sessionID,
    lifecycleEvent: eventName,
    cwd: value("cwd", in: input) ?? FileManager.default.currentDirectoryPath,
    processID: process?.pid,
    processStartIdentity: process?.startIdentity,
    tty: process?.tty,
    model: value("model", in: input),
    toolName: value("tool_name", in: input),
    startSource: value("source", in: input),
    endReason: value("reason", in: input),
    notificationType: value("notification_type", in: input)
)

let encoder = JSONEncoder()
guard let encoded = try? encoder.encode(event) else { exit(0) }
spool(encoded, eventID: event.eventID)
sendToRunningApp(encoded)
exit(0)
