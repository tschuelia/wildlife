import AppKit
import SwiftUI

@main
struct WildlifeApp: App {
    @NSApplicationDelegateAdaptor(WildlifeAppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var repository: SessionRepository
    @StateObject private var integrations: IntegrationManager
    @StateObject private var runtime: AppRuntime

    init() {
        let settings = AppSettings()
        let repository: SessionRepository
        do {
            repository = try SessionRepository()
        } catch {
            fatalError("Wildlife could not open its local database: \(error.localizedDescription)")
        }
        _settings = StateObject(wrappedValue: settings)
        _repository = StateObject(wrappedValue: repository)
        _integrations = StateObject(wrappedValue: IntegrationManager(settings: settings))
        _runtime = StateObject(wrappedValue: AppRuntime(repository: repository, settings: settings))
    }

    var body: some Scene {
        Window("Wildlife", id: "manager") {
            ManagerView(
                repository: repository,
                settings: settings,
                integrations: integrations,
                runtime: runtime
            )
            .environmentObject(runtime.sessionActions)
            .environmentObject(runtime)
        }
        .defaultSize(width: 1_250, height: 760)
        .commands {
            SessionCommands(repository: repository, settings: settings, actions: runtime.sessionActions)
        }

        MenuBarExtra("Wildlife", systemImage: "pawprint.fill") {
            WildlifeMenuContent(repository: repository, settings: settings, runtime: runtime)
                .environmentObject(runtime.sessionActions)
        }
        .menuBarExtraStyle(.window)

        Settings {
            WildlifeSettingsView(settings: settings, integrations: integrations, runtime: runtime)
        }
    }
}

private final class WildlifeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct WildlifeMenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    @ObservedObject var runtime: AppRuntime

    var body: some View {
        QuickView(repository: repository, settings: settings) { key in
            runtime.openManager(sessionKey: key)
        }
        .task {
            runtime.start {
                openWindow(id: "manager")
            }
        }
    }
}
