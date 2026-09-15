import Darwin
import Foundation

package enum LocalSecurityError: LocalizedError {
    case unsafePath(URL, String)

    package var errorDescription: String? {
        switch self {
        case .unsafePath(let url, let reason):
            "Unsafe local path \(url.path): \(reason)"
        }
    }
}

package enum SecureLocalFile {
    package static let privateDirectoryMode: mode_t = 0o700
    package static let privateFileMode: mode_t = 0o600
    package static let executableFileMode: mode_t = 0o700

    package static func ensurePrivateDirectory(at url: URL) throws {
        try ensureOwnedDirectory(at: url, mode: privateDirectoryMode)
    }

    package static func ensureOwnedDirectory(at url: URL, mode: mode_t? = nil) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: mode.map { [.posixPermissions: NSNumber(value: $0)] }
        )

        let info = try fileInfo(at: url)
        guard fileType(info.st_mode) == S_IFDIR else {
            throw LocalSecurityError.unsafePath(url, "expected a directory")
        }
        guard info.st_uid == geteuid() else {
            throw LocalSecurityError.unsafePath(url, "directory is owned by another user")
        }
        if let mode, chmod(url.path, mode) != 0 {
            throw POSIXError(currentPOSIXError())
        }
    }

    package static func writeAtomically(
        _ data: Data,
        to destination: URL,
        mode: mode_t = privateFileMode
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try ensureOwnedDirectory(at: parent)
        if let existing = try optionalFileInfo(at: destination) {
            guard existing.st_uid == geteuid() else {
                throw LocalSecurityError.unsafePath(destination, "file is owned by another user")
            }
            guard fileType(existing.st_mode) == S_IFREG else {
                throw LocalSecurityError.unsafePath(destination, "expected a regular file")
            }
        }

        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw POSIXError(currentPOSIXError()) }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { close(descriptor) }
            unlink(staging.path)
        }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                guard count > 0 else { throw POSIXError(currentPOSIXError()) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(currentPOSIXError()) }
        let closeResult = close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw POSIXError(currentPOSIXError()) }
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(currentPOSIXError())
        }
    }

    package static func readPrivateFile(
        at url: URL,
        maximumSize: Int? = nil,
        mode: mode_t = privateFileMode
    ) throws -> Data {
        let info = try fileInfo(at: url)
        guard info.st_uid == geteuid() else {
            throw LocalSecurityError.unsafePath(url, "file is owned by another user")
        }
        guard fileType(info.st_mode) == S_IFREG else {
            throw LocalSecurityError.unsafePath(url, "expected a regular file")
        }
        if let maximumSize, info.st_size > maximumSize {
            throw LocalSecurityError.unsafePath(url, "file exceeds the size limit")
        }
        if info.st_mode & 0o777 != mode, chmod(url.path, mode) != 0 {
            throw POSIXError(currentPOSIXError())
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    package static func removeOwnedFileOrLink(at url: URL) throws {
        guard let info = try optionalFileInfo(at: url) else { return }
        guard info.st_uid == geteuid() else {
            throw LocalSecurityError.unsafePath(url, "entry is owned by another user")
        }
        let type = fileType(info.st_mode)
        guard type == S_IFREG || type == S_IFLNK else {
            throw LocalSecurityError.unsafePath(url, "expected a regular file or symbolic link")
        }
        guard unlink(url.path) == 0 else { throw POSIXError(currentPOSIXError()) }
    }

    package static func removeOwnedSocket(at url: URL) throws {
        guard let info = try optionalFileInfo(at: url) else { return }
        guard info.st_uid == geteuid(), fileType(info.st_mode) == S_IFSOCK else {
            throw LocalSecurityError.unsafePath(url, "expected a socket owned by the current user")
        }
        guard unlink(url.path) == 0 else { throw POSIXError(currentPOSIXError()) }
    }

    private static func fileInfo(at url: URL) throws -> stat {
        guard let info = try optionalFileInfo(at: url) else {
            throw POSIXError(.ENOENT)
        }
        return info
    }

    private static func optionalFileInfo(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw POSIXError(currentPOSIXError())
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & S_IFMT
    }

    private static func currentPOSIXError() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }
}
