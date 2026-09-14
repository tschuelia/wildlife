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

    init(repository: SessionRepository, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
    }

    func start() {
        guard !started else { return }
        started = true
        replayInbox()
        do {
            try server.start { [weak repository] event in
                Task { @MainActor in repository?.consume(event) }
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
        let candidate = NSApp.windows.first {
            !$0.className.contains("NSStatusBar") && !$0.className.contains("Popover") && $0.canBecomeMain
        }
        candidate?.makeKeyAndOrderFront(nil)
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
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: RuntimePaths.inboxDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let decoder = JSONDecoder()
        let events = urls.compactMap { url -> BridgeEvent? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(BridgeEvent.self, from: data)
        }.sorted { $0.timestamp < $1.timestamp }
        for event in events { repository.consume(event) }
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
