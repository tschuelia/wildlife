import Foundation
import Observation
import WildlifeDomain
import WildlifeInfrastructure

@MainActor
@Observable
final class IntegrationManager {
    private(set) var states: [AgentProvider: HookInstallationState] = [:]
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var errorMessage: String?

    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func refresh() async {
        let settings = preferences.value
        states = await Task.detached(priority: .utility) {
            let bridgeIsCurrent = Self.installedBridgeIsCurrent()
            return Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { provider in
                let state = HookConfiguration.installationState(
                    provider: provider,
                    configURL: settings.configURL(for: provider),
                    bridgeURL: RuntimePaths.installedBridgeURL
                )
                return (provider, state == .installed && !bridgeIsCurrent ? .needsRepair : state)
            })
        }.value
    }

    func installAll() async {
        await perform { settings in
            try Self.installBridge()
            var backups: [String] = []
            for provider in AgentProvider.allCases {
                let result = try HookConfiguration.install(
                    provider: provider,
                    configURL: settings.configURL(for: provider),
                    bridgeURL: RuntimePaths.installedBridgeURL
                )
                if let backup = result.backupURL { backups.append(backup.path) }
            }
            return backups.isEmpty
                ? "Integrations installed. Start a new agent session."
                : "Integrations installed. Backups: \(backups.joined(separator: ", "))"
        }
        if errorMessage == nil { preferences.value.onboardingCompleted = true }
    }

    func uninstallAll() async {
        await perform { settings in
            for provider in AgentProvider.allCases {
                _ = try HookConfiguration.uninstall(
                    provider: provider,
                    configURL: settings.configURL(for: provider),
                    bridgeURL: RuntimePaths.installedBridgeURL
                )
            }
            try SecureLocalFile.removeOwnedFileOrLink(at: RuntimePaths.installedBridgeURL)
            return "Wildlife hooks were removed. Provider sessions were not changed."
        }
    }

    private func perform(_ operation: @escaping @Sendable (AppPreferences) throws -> String) async {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        errorMessage = nil
        let settings = preferences.value
        do {
            message = try await Task.detached(priority: .userInitiated) { try operation(settings) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
        await refresh()
    }

    private nonisolated static func installBridge() throws {
        try RuntimePaths.prepareDirectories()
        guard let source = bundledBridgeURL() else { throw HookConfigurationError.missingBridgeBinary }
        let data = try Data(contentsOf: source)
        try SecureLocalFile.writeAtomically(data, to: RuntimePaths.installedBridgeURL, mode: SecureLocalFile.executableFileMode)
    }

    private nonisolated static func bundledBridgeURL() -> URL? {
        let manager = FileManager.default
        let executable = Bundle.main.executableURL
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("wildlife-hook"),
            executable?.deletingLastPathComponent().appendingPathComponent("wildlife-hook"),
            executable?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wildlife-hook"),
        ].compactMap { $0 }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

    private nonisolated static func installedBridgeIsCurrent() -> Bool {
        guard let source = bundledBridgeURL(),
              let expected = try? Data(contentsOf: source),
              let installed = try? SecureLocalFile.readOwnedRegularFile(
                  at: RuntimePaths.installedBridgeURL,
                  requiredMode: SecureLocalFile.executableFileMode
              ) else {
            return false
        }
        return expected == installed
    }
}
