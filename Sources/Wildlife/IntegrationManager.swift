import AppKit
import Combine
import Foundation
import WildlifeCore

@MainActor
final class IntegrationManager: ObservableObject {
    @Published private(set) var codexState: HookInstallationState = .notInstalled
    @Published private(set) var claudeState: HookInstallationState = .notInstalled
    @Published var lastMessage: String?
    @Published var lastError: String?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        refresh()
        refreshInstalledBridgeIfNeeded()
        repairExistingIntegrations()
        refresh()
    }

    private func refreshInstalledBridgeIfNeeded() {
        guard codexState != .notInstalled || claudeState != .notInstalled else { return }
        do {
            try installBridge()
        } catch {
            lastError = "Bridge update: \(error.localizedDescription)"
        }
    }

    private func repairExistingIntegrations() {
        var repairedProviders: [String] = []
        var backups: [String] = []
        var errors: [String] = []

        for provider in AgentProvider.allCases {
            do {
                let result = try HookConfiguration.repairExistingHandlers(
                    provider: provider,
                    configURL: settings.configURL(for: provider),
                    bridgeURL: RuntimePaths.installedBridgeURL
                )
                if result.changed { repairedProviders.append(provider.displayName) }
                if let backup = result.backupURL { backups.append(backup.path) }
            } catch {
                errors.append("\(provider.displayName): \(error.localizedDescription)")
            }
        }

        if !repairedProviders.isEmpty {
            let names = repairedProviders.joined(separator: " and ")
            lastMessage = "Updated existing \(names) handlers. Restart or resume active sessions. Backups: \(backups.joined(separator: ", "))"
        }
        if !errors.isEmpty {
            lastError = ([lastError].compactMap { $0 } + errors).joined(separator: "\n")
        }
    }

    func refresh() {
        codexState = HookConfiguration.installationState(
            provider: .codex,
            configURL: settings.configURL(for: .codex),
            bridgeURL: RuntimePaths.installedBridgeURL
        )
        claudeState = HookConfiguration.installationState(
            provider: .claude,
            configURL: settings.configURL(for: .claude),
            bridgeURL: RuntimePaths.installedBridgeURL
        )
    }

    func installAll() {
        lastError = nil
        do {
            try installBridge()
            let codex = try HookConfiguration.install(
                provider: .codex,
                configURL: settings.configURL(for: .codex),
                bridgeURL: RuntimePaths.installedBridgeURL
            )
            let claude = try HookConfiguration.install(
                provider: .claude,
                configURL: settings.configURL(for: .claude),
                bridgeURL: RuntimePaths.installedBridgeURL
            )
            let backups = [codex.backupURL, claude.backupURL].compactMap { $0?.path }
            lastMessage = backups.isEmpty
                ? "Integrations are installed. Restart or resume active sessions."
                : "Integrations installed. Backups: \(backups.joined(separator: ", "))"
            settings.onboardingCompleted = true
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstallAll() {
        lastError = nil
        do {
            _ = try HookConfiguration.uninstall(
                provider: .codex,
                configURL: settings.configURL(for: .codex),
                bridgeURL: RuntimePaths.installedBridgeURL
            )
            _ = try HookConfiguration.uninstall(
                provider: .claude,
                configURL: settings.configURL(for: .claude),
                bridgeURL: RuntimePaths.installedBridgeURL
            )
            try? FileManager.default.removeItem(at: RuntimePaths.installedBridgeURL)
            lastMessage = "Wildlife handlers were removed. Agent session files were not changed."
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func installBridge() throws {
        try RuntimePaths.prepareDirectories()
        guard let source = bundledBridgeURL() else { throw HookConfigurationError.missingBridgeBinary }
        let destination = RuntimePaths.installedBridgeURL
        let bundledData = try Data(contentsOf: source)
        if let installedData = try? SecureLocalFile.readPrivateFile(
            at: destination,
            mode: SecureLocalFile.executableFileMode
        ),
           installedData == bundledData {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: SecureLocalFile.executableFileMode)],
                ofItemAtPath: destination.path
            )
            return
        }
        try SecureLocalFile.writeAtomically(
            bundledData,
            to: destination,
            mode: SecureLocalFile.executableFileMode
        )
    }

    private func bundledBridgeURL() -> URL? {
        let manager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("wildlife-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("wildlife-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wildlife-hook"),
        ].compactMap { $0 }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }
}
