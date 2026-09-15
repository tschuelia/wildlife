import AppKit
import Foundation
import Observation
import WildlifeDomain
import WildlifeInfrastructure

@MainActor
@Observable
final class AppCoordinator {
    private(set) var isImportingHistory = false
    private(set) var runtimeError: String?

    let actions: SessionActionController
    let notifications = AttentionNotificationController()

    private let library: SessionLibrary
    private let preferences: PreferencesStore
    private let eventServer = LocalEventServer()
    private var eventTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?
    private var notchController: NotchPanelController?
    private var openManagerWindow: (() -> Void)?
    private var started = false

    init(library: SessionLibrary, preferences: PreferencesStore) {
        self.library = library
        self.preferences = preferences
        actions = SessionActionController(library: library, preferences: preferences)
        notifications.configure { [weak self] action, id in
            self?.handleNotificationAction(action, sessionID: id)
        }
    }

    func start(openManager: (() -> Void)? = nil) async {
        if let openManager { openManagerWindow = openManager }
        guard !started else { return }
        started = true
        await library.load()
        guard library.isLoaded else {
            runtimeError = library.errorMessage
            started = false
            return
        }

        await replayInbox()
        startEventStream()
        startMaintenance()
        notchController = NotchPanelController(
            library: library,
            focusSession: { [weak self] session in self?.focusOrOpen(session) ?? false },
            openManager: { [weak self] in self?.openManager() }
        )
        await runMaintenance(includeHistory: false)
        await importHistory(since: Date().addingTimeInterval(-7 * 86_400))
    }

    func stop() {
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        maintenanceTask?.cancel()
        historyTask?.cancel()
        eventServer.stop()
        notchController?.shutdown()
        notchController = nil
        eventTask = nil
        maintenanceTask = nil
        historyTask = nil
        started = false
    }

    func retryStartup() async {
        stop()
        runtimeError = nil
        await library.retryLoad()
        await start(openManager: openManagerWindow)
    }

    func clearError() { runtimeError = nil }

    func openManager(sessionID: SessionID? = nil) {
        if let sessionID { library.selectedSessionID = sessionID }
        NSApp.activate(ignoringOtherApps: true)
        openManagerWindow?()
    }

    func importOlderHistory() async {
        library.showOlderSessions()
        await importHistory(since: .distantPast)
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            preferences.value.notifications.enabled = await notifications.requestAuthorization()
        } else {
            preferences.value.notifications.enabled = false
            notifications.cancelAllSnoozes()
        }
    }

    func snooze(_ session: Session, until date: Date) async {
        await library.snooze(session.id, until: date)
        if preferences.value.notifications.enabled,
           let updated = library.session(session.id) {
            notifications.scheduleSnooze(for: updated, until: date)
        }
    }

    private func startEventStream() {
        let pair = AsyncStream<AgentEvent>.makeStream()
        eventContinuation = pair.continuation
        do {
            try eventServer.start { event in pair.continuation.yield(event) }
        } catch {
            runtimeError = "Live event transport is unavailable; inbox replay remains active. \(error.localizedDescription)"
        }
        eventTask = Task { [weak self] in
            for await event in pair.stream {
                guard !Task.isCancelled, let self else { break }
                await self.consumeLive(event)
            }
        }
    }

    private func startMaintenance() {
        maintenanceTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
                guard let self else { break }
                tick += 1
                await self.runMaintenance(includeHistory: tick.isMultiple(of: 12))
            }
        }
    }

    private func runMaintenance(includeHistory: Bool) async {
        await library.runMaintenance(
            rules: preferences.value.organizationRules,
            liveness: ProcessInspector.liveness
        )
        await replayInbox()
        await refreshProjects(library.activeSessions, refreshExisting: includeHistory)
        if includeHistory { await importHistory(since: Date().addingTimeInterval(-7 * 86_400)) }
    }

    private func consumeLive(_ event: AgentEvent) async {
        let transition = await library.consume(event, rules: preferences.value.organizationRules)
        guard library.errorMessage == nil else { return }
        removeSpool(for: event)
        guard let transition, let session = library.session(transition.sessionID) else { return }
        if session.attentionReason() == nil { notifications.cancelSnooze(for: session.id) }
        notifications.notify(transition: transition, session: session, preferences: preferences.value.notifications)
        await refreshProjects([session], refreshExisting: false)
    }

    private func replayInbox() async {
        let result = await Task.detached(priority: .utility) { Self.readInbox() }.value
        for item in result {
            guard !Task.isCancelled else { return }
            if let event = item.event {
                _ = await library.consume(event, rules: preferences.value.organizationRules)
                guard library.errorMessage == nil else { return }
            }
            do { try SecureLocalFile.removeOwnedFileOrLink(at: item.url) }
            catch { runtimeError = error.localizedDescription }
        }
    }

    private func importHistory(since cutoff: Date) async {
        guard historyTask == nil else { return }
        isImportingHistory = true
        let settings = preferences.value
        let task = Task.detached(priority: .utility) {
            HistoricalImporter().importSessions(
                codexHome: URL(fileURLWithPath: settings.codexHome, isDirectory: true),
                claudeHome: URL(fileURLWithPath: settings.claudeHome, isDirectory: true),
                since: cutoff
            )
        }
        historyTask = Task { [weak self] in
            let imported = await task.value
            guard let self, !Task.isCancelled else { return }
            _ = await self.library.importSessions(imported)
            await self.refreshProjects(self.library.sessions, refreshExisting: false)
            self.isImportingHistory = false
            self.historyTask = nil
        }
        await historyTask?.value
    }

    private func refreshProjects(_ sessions: [Session], refreshExisting: Bool) async {
        let candidates = sessions.filter { !$0.cwd.isEmpty && (refreshExisting || $0.project == nil) }
        let results = await withTaskGroup(of: (SessionID, ProjectMetadata?).self) { group in
            for session in candidates {
                group.addTask { (session.id, GitProjectInspector().inspect(cwd: session.cwd)) }
            }
            var values: [(SessionID, ProjectMetadata?)] = []
            for await value in group { values.append(value) }
            return values
        }
        for (id, project) in results { await library.updateProject(project, sessionID: id) }
    }

    private func focusOrOpen(_ session: Session) -> Bool {
        guard actions.focus(session) else {
            openManager(sessionID: session.id)
            return false
        }
        return true
    }

    private func handleNotificationAction(_ action: WildlifeNotificationAction, sessionID: SessionID) {
        guard let session = library.session(sessionID) else { return }
        switch action {
        case .open: openManager(sessionID: sessionID)
        case .focus: _ = focusOrOpen(session)
        case .snooze: Task { await snooze(session, until: Date().addingTimeInterval(3_600)) }
        }
    }

    private func removeSpool(for event: AgentEvent) {
        guard let url = RuntimePaths.spoolURL(eventID: event.id) else { return }
        do { try SecureLocalFile.removeOwnedFileOrLink(at: url) }
        catch { runtimeError = error.localizedDescription }
    }

    private struct InboxItem: Sendable {
        let url: URL
        let event: AgentEvent?
    }

    private nonisolated static func readInbox() -> [InboxItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: RuntimePaths.inboxDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.map { url in
            let event: AgentEvent?
            do {
                let data = try SecureLocalFile.readPrivateFile(
                    at: url,
                    maximumSize: LocalEventTransport.maximumPayloadSize
                )
                event = try JSONDecoder().decode(AgentEvent.self, from: data)
            } catch {
                event = nil
            }
            let validated = event.flatMap { $0.isValid && url.lastPathComponent == "\($0.id).json" ? $0 : nil }
            return InboxItem(url: url, event: validated)
        }.sorted { lhs, rhs in
            (lhs.event?.timestamp ?? .distantPast) < (rhs.event?.timestamp ?? .distantPast)
        }
    }
}
