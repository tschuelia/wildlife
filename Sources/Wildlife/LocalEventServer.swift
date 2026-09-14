import Darwin
import Foundation
import WildlifeCore

final class LocalEventServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.wildlife.event-server", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private let socketURL: URL

    init(socketURL: URL = RuntimePaths.socketURL) {
        self.socketURL = socketURL
    }

    func start(handler: @escaping @Sendable (BridgeEvent) -> Void) throws {
        if descriptor >= 0 { return }
        try? FileManager.default.removeItem(at: socketURL)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_un()
        let pathBytes = Array(socketURL.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(length)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard result == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        chmod(socketURL.path, 0o600)
        descriptor = fd

        queue.async { [weak self] in
            self?.acceptLoop(handler: handler)
        }
    }

    func stop() {
        let fd = descriptor
        descriptor = -1
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop(handler: @escaping @Sendable (BridgeEvent) -> Void) {
        while descriptor >= 0 {
            let client = accept(descriptor, nil, nil)
            if client < 0 { continue }
            let data = readAll(client)
            close(client)
            if data.count <= 65_536,
               let event = try? JSONDecoder().decode(BridgeEvent.self, from: data) {
                handler(event)
            }
        }
    }

    private func readAll(_ descriptor: Int32) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while result.count <= 65_536 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    deinit { stop() }
}
