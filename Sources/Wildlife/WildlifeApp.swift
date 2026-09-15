import AppKit
import Observation
import SwiftUI
import WildlifeInfrastructure

@MainActor
@Observable
final class ApplicationModel {
    let preferences = PreferencesStore()
    private(set) var library: SessionLibrary?
    private(set) var integrations: IntegrationManager?
    private(set) var coordinator: AppCoordinator?
    private(set) var startupError: String?

    init() {
        bootstrap()
    }

    func bootstrap() {
        do {
            let database = try SessionDatabase(url: RuntimePaths.databaseURL)
            let library = SessionLibrary(database: database)
            self.library = library
            integrations = IntegrationManager(preferences: preferences)
            coordinator = AppCoordinator(library: library, preferences: preferences)
            startupError = nil
        } catch {
            library = nil
            integrations = nil
            coordinator = nil
            startupError = error.localizedDescription
        }
    }
}

@main
struct WildlifeApp: App {
    @NSApplicationDelegateAdaptor(WildlifeAppDelegate.self) private var appDelegate
    @State private var application = ApplicationModel()

    var body: some Scene {
        Window("Wildlife", id: "manager") {
            if let library = application.library,
               let integrations = application.integrations,
               let coordinator = application.coordinator {
                ManagerView(
                    library: library,
                    preferences: application.preferences,
                    integrations: integrations,
                    coordinator: coordinator,
                    actions: coordinator.actions
                )
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    coordinator.stop()
                }
            } else {
                StartupFailureView(error: application.startupError, retry: application.bootstrap)
            }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands { SessionCommands(application: application) }

        MenuBarExtra("Wildlife", systemImage: "pawprint.fill") {
            WildlifeMenuContent(application: application)
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let integrations = application.integrations, let coordinator = application.coordinator {
                WildlifeSettingsView(
                    preferences: application.preferences,
                    integrations: integrations,
                    coordinator: coordinator
                )
            } else {
                StartupFailureView(error: application.startupError, retry: application.bootstrap)
                    .frame(width: 480, height: 260)
            }
        }
    }
}

private struct WildlifeMenuContent: View {
    let application: ApplicationModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let library = application.library, let coordinator = application.coordinator {
            QuickView(library: library, actions: coordinator.actions) { id in
                coordinator.openManager(sessionID: id)
            }
            .task { await coordinator.start { openWindow(id: "manager") } }
        } else {
            StartupFailureView(error: application.startupError, retry: application.bootstrap)
                .frame(width: 330, height: 180)
        }
    }
}

private struct StartupFailureView: View {
    let error: String?
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Wildlife could not open its database", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(error ?? "Unknown database error")
        } actions: {
            Button("Retry", action: retry)
            Button("Reveal Data Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([RuntimePaths.applicationSupportDirectory])
            }
        }
        .padding()
    }
}

private final class WildlifeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
