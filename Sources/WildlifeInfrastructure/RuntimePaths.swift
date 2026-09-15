import Foundation
import WildlifeDomain

package enum RuntimePaths {
    package static var applicationSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WILDLIFE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wildlife", isDirectory: true)
    }

    package static var databaseURL: URL {
        applicationSupportDirectory.appendingPathComponent("Wildlife.sqlite3")
    }

    package static var inboxDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Inbox", isDirectory: true)
    }

    package static var installedBridgeURL: URL {
        applicationSupportDirectory.appendingPathComponent("bin/wildlife-hook")
    }

    package static var socketURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wildlife-\(getuid()).sock")
    }

    package static func spoolURL(eventID: String) -> URL? {
        guard UUID(uuidString: eventID) != nil else { return nil }
        return inboxDirectory.appendingPathComponent("\(eventID).json", isDirectory: false)
    }

    package static func prepareDirectories() throws {
        try SecureLocalFile.ensurePrivateDirectory(at: applicationSupportDirectory)
        try SecureLocalFile.ensurePrivateDirectory(at: inboxDirectory)
        try SecureLocalFile.ensurePrivateDirectory(at: installedBridgeURL.deletingLastPathComponent())
    }
}
