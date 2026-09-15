import Darwin
import Foundation

package enum LocalEventTransport {
    package static let maximumPayloadSize = 65_536
    package static let receiveTimeout: TimeInterval = 2

    @discardableResult
    package static func send(_ data: Data, to socketURL: URL = RuntimePaths.socketURL) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumPayloadSize,
              var address = socketAddress(path: socketURL.path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let connected = withUnsafePointer(to: &address.address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, address.length)
            }
        }
        guard connected == 0, peerBelongsToCurrentUser(descriptor) else { return false }

        let fullySent = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
        if fullySent { shutdown(descriptor, SHUT_WR) }
        return fullySent
    }

    package static func peerBelongsToCurrentUser(_ descriptor: Int32) -> Bool {
        var effectiveUID = uid_t.max
        var effectiveGID = gid_t.max
        return getpeereid(descriptor, &effectiveUID, &effectiveGID) == 0
            && peerUIDIsAllowed(effectiveUID)
    }

    package static func peerUIDIsAllowed(_ effectiveUID: uid_t) -> Bool {
        effectiveUID == geteuid()
    }

    fileprivate static func socketAddress(path: String) -> (address: sockaddr_un, length: socklen_t)? {
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
}

package final class LocalEventServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.wildlife.event-server", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private let socketURL: URL

    package init(socketURL: URL = RuntimePaths.socketURL) {
        self.socketURL = socketURL
    }

    package func start(handler: @escaping @Sendable (BridgeEvent) -> Void) throws {
        if descriptor >= 0 { return }
        try SecureLocalFile.removeOwnedSocket(at: socketURL)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        guard var address = LocalEventTransport.socketAddress(path: socketURL.path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        let bindResult = withUnsafePointer(to: &address.address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, address.length)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(currentPOSIXError())
        }
        guard chmod(socketURL.path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = currentPOSIXError()
            close(fd)
            try? SecureLocalFile.removeOwnedSocket(at: socketURL)
            throw POSIXError(error)
        }
        descriptor = fd

        queue.async { [weak self] in
            self?.acceptLoop(handler: handler)
        }
    }

    package func stop() {
        let fd = descriptor
        descriptor = -1
        if fd >= 0 { close(fd) }
        try? SecureLocalFile.removeOwnedSocket(at: socketURL)
    }

    private func acceptLoop(handler: @escaping @Sendable (BridgeEvent) -> Void) {
        while descriptor >= 0 {
            let client = accept(descriptor, nil, nil)
            if client < 0 { continue }
            defer { close(client) }
            guard LocalEventTransport.peerBelongsToCurrentUser(client) else { continue }
            configureReceiveTimeout(client)
            guard let data = readAll(client),
                  let event = try? JSONDecoder().decode(BridgeEvent.self, from: data),
                  event.isValidForTransport else { continue }
            handler(event)
        }
    }

    private func configureReceiveTimeout(_ descriptor: Int32) {
        let seconds = Int(LocalEventTransport.receiveTimeout)
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
    }

    private func readAll(_ descriptor: Int32) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while result.count <= LocalEventTransport.maximumPayloadSize {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 { return nil }
            guard result.count + count <= LocalEventTransport.maximumPayloadSize else { return nil }
            result.append(buffer, count: count)
        }
        return nil
    }

    deinit { stop() }

    private func currentPOSIXError() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }
}
