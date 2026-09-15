import AppKit
import Combine
import Foundation
import WildlifeCore

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var isImportingOlderHistory = false

    private let repository: SessionRepository
    private let settings: AppSettings
    private let server = LocalEventServer()
    let sessionActions: SessionActionController
    private let notifications = AttentionNotificationController()
    private var timer: Timer?
    private var started = false
    private var reconciliationTicks = 0
    private var notchController: NotchPanelController?
    private var openManagerWindow: (() -> Void)?
    private var projectMetadataInFlight = Set<String>()
    private var inspectedProjectCWD: [String: String] = [:]

    init(repository: SessionRepository, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
        sessionActions = SessionActionController(repository: repository, settings: settings)
        notifications.configure { [weak self] action, key in
            self?.handleNotificationAction(action, sessionKey: key)
        }
    }

    func start(openManager: (() -> Void)? = nil) {
        if let openManager { openManagerWindow = openManager }
        guard !started else { return }
        started = true
        replayInbox()
        do {
            try server.start { [weak self] event in
                Task { @MainActor in
                    self?.consumeLive(event)
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
        notchController = NotchPanelController(
            repository: repository,
            focusSession: { [weak self] session in
                guard let self else { return false }
                guard sessionActions.focus(session) else {
                    self.openManager(sessionKey: session.stableKey)
                    return false
                }
                return true
            },
            openManager: { [weak self] in self?.openManager() }
        )
        repository.applyAutomaticArchive(rules: settings.organizationRules)
        refreshProjectMetadata(for: repository.sessions)
        importHistory(since: SessionHistoryPolicy.cutoff()) {
            self.settings.initialImportCompleted = true
        }
    }

    func importOlderHistory() {
        repository.showOlderSessions()
        guard !isImportingOlderHistory else { return }
        isImportingOlderHistory = true
        importHistory(since: .distantPast) { [weak self] in
            self?.isImportingOlderHistory = false
        }
    }

    func openManager(sessionKey: String? = nil) {
        if let sessionKey { repository.selectedSessionKey = sessionKey }
        NSApp.activate(ignoringOtherApps: true)
        openManagerWindow?()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.notificationsEnabled = false
            for session in repository.sessions {
                notifications.cancelSnooze(for: session.stableKey)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            settings.notificationsEnabled = await notifications.requestAuthorization()
        }
    }

    func snooze(_ session: SessionRecord, until date: Date) {
        repository.snooze(session, until: date)
        if settings.notificationsEnabled {
            notifications.scheduleSnooze(for: session, until: date)
        }
    }

    private func tick() {
        reconciliationTicks += 1
        repository.clearExpiredSnoozes()
        repository.reconcileProcesses(rules: settings.organizationRules)
        repository.releaseOldAutomaticEmojis()
        replayInbox()
        if reconciliationTicks.isMultiple(of: 12) {
            repository.applyAutomaticArchive(rules: settings.organizationRules)
            refreshProjectMetadata(for: repository.activeSessions, refreshingExisting: true)
            importHistory(since: SessionHistoryPolicy.cutoff())
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
            _ = repository.consume(event, rules: settings.organizationRules)
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
            if let self { self.refreshProjectMetadata(for: self.repository.sessions) }
            completion?()
        }
    }

    private func consumeLive(_ event: BridgeEvent) {
        guard let transition = repository.consume(event, rules: settings.organizationRules),
              let session = repository.session(forKey: transition.sessionKey) else { return }
        if session.attentionReason() == nil {
            notifications.cancelSnooze(for: session.stableKey)
        }
        notifications.notify(transition: transition, session: session, settings: settings)
        refreshProjectMetadata(for: [session])
    }

    private func handleNotificationAction(_ action: WildlifeNotificationAction, sessionKey: String) {
        guard let session = repository.session(forKey: sessionKey) else { return }
        switch action {
        case .open:
            openManager(sessionKey: sessionKey)
        case .focus:
            if !sessionActions.focus(session) { openManager(sessionKey: sessionKey) }
        case .snooze:
            snooze(session, until: Date().addingTimeInterval(3_600))
        }
    }

    private func refreshProjectMetadata(
        for sessions: [SessionRecord],
        refreshingExisting: Bool = false
    ) {
        for session in sessions {
            let key = session.stableKey
            let cwd = session.cwd
            guard !cwd.isEmpty,
                  (refreshingExisting || inspectedProjectCWD[key] != cwd),
                  projectMetadataInFlight.insert(key).inserted else { continue }
            inspectedProjectCWD[key] = cwd
            let task = Task.detached(priority: .utility) {
                GitProjectInspector().inspect(cwd: cwd)
            }
            Task { [weak self] in
                let metadata = await task.value
                guard let self else { return }
                projectMetadataInFlight.remove(key)
                repository.updateProjectMetadata(metadata, forSessionKey: key)
            }
        }
    }
}
