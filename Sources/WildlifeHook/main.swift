import Foundation
import WildlifeCore

private func spool(_ data: Data, eventID: String) {
    do {
        try RuntimePaths.prepareDirectories()
        guard let destination = RuntimePaths.spoolURL(eventID: eventID) else { return }
        try SecureLocalFile.writeAtomically(data, to: destination)
    } catch {
        // Hooks fail open. An unavailable inbox must never affect the agent.
    }
}

private func run() {
    guard CommandLine.arguments.count >= 2,
          let provider = AgentProvider(rawValue: CommandLine.arguments[1]),
          var inputData = try? FileHandle.standardInput.readToEnd(),
          !inputData.isEmpty else { return }
    defer {
        inputData.resetBytes(in: 0..<inputData.count)
        inputData.removeAll(keepingCapacity: false)
    }

    let process = ProcessInspector.captureAgentProcess(provider: provider)
    guard let event = try? BridgeEventFactory.decodeHookInput(
        inputData,
        provider: provider,
        fallbackCWD: FileManager.default.currentDirectoryPath,
        process: process
    ), let encoded = try? JSONEncoder().encode(event) else { return }

    spool(encoded, eventID: event.eventID)
    LocalEventTransport.send(encoded)
}

run()
