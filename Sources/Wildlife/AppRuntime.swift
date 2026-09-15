import AppKit
import Combine
import Foundation
import WildlifeCore

@MainActor
final class AppRuntime: ObservableObject {
    private let repository: SessionRepository
    private let settings: AppSettings
    private let server = LocalEventServer()
    private var timer: Timer?
    private var started = false
    private var reconciliationTicks = 0
    private var notchController: NotchPanelController?
    private var openManagerWindow: (() -> Void)?

    init(repository: SessionRepository, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
    }

    func start(openManager: (() -> Void)? = nil) {
        if let openManager { openManagerWindow = openManager }
        guard !started else { return }
        started = true
        replayInbox()
        do {
            try server.start { [weak repository] event in
                Task { @MainActor in
                    repository?.consume(event)
                    if let spoolURL = RuntimePaths.spoolURL(eventID: event.eventID) {
                        try? SecureLocalFile.removeOwnedFileOrLink(at: spoolURL)
                    }
                }
            }
        } catch {
            // The inbox remains the durable fallback if a local socket cannot be created.
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        notchController = NotchPanelController(repository: repository) { [weak self] in
            self?.openManager()
        }
        importHistory(since: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast) {
            self.settings.initialImportCompleted = true
        }
    }

    func importOlderHistory() {
        importHistory(since: .distantPast, completion: nil)
    }

    func openManager(sessionKey: String? = nil) {
        if let sessionKey { repository.selectedSessionKey = sessionKey }
        NSApp.activate(ignoringOtherApps: true)
        openManagerWindow?()
    }

    private func tick() {
        reconciliationTicks += 1
        repository.reconcileProcesses()
        replayInbox()
        if reconciliationTicks.isMultiple(of: 12) {
            importHistory(since: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast)
        }
    }

    private func replayInbox() {
        let inbox = RuntimePaths.inboxDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let decoder = JSONDecoder()
        let events = urls.compactMap { url -> (URL, BridgeEvent)? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? SecureLocalFile.readPrivateFile(
                at: url,
                maximumSize: LocalEventTransport.maximumPayloadSize
            ), let event = try? decoder.decode(BridgeEvent.self, from: data),
            event.isValidForTransport,
            url.lastPathComponent == "\(event.eventID).json" else {
                try? SecureLocalFile.removeOwnedFileOrLink(at: url)
                return nil
            }
            return (url, event)
        }.sorted { $0.1.timestamp < $1.1.timestamp }
        for (url, event) in events {
            repository.consume(event)
            try? SecureLocalFile.removeOwnedFileOrLink(at: url)
        }
    }

    private func importHistory(since cutoff: Date, completion: (() -> Void)? = nil) {
        let codex = URL(fileURLWithPath: settings.codexHome, isDirectory: true)
        let claude = URL(fileURLWithPath: settings.claudeHome, isDirectory: true)
        let importTask = Task.detached(priority: .utility) {
            HistoricalImporter().importSessions(codexHome: codex, claudeHome: claude, since: cutoff)
        }
        Task { [weak self] in
            let sessions = await importTask.value
            _ = self?.repository.importSessions(sessions)
            completion?()
        }
    }
}
