import ServiceManagement
import SwiftUI
import WildlifeDomain
import WildlifeInfrastructure

struct WildlifeSettingsView: View {
    @Bindable var preferences: PreferencesStore
    @Bindable var integrations: IntegrationManager
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettings(preferences: preferences, coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gear") }
            IntegrationSettings(preferences: preferences, integrations: integrations)
                .tabItem { Label("Integrations", systemImage: "link") }
            NotificationSettings(preferences: preferences, coordinator: coordinator)
                .tabItem { Label("Notifications", systemImage: "bell") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(width: 660, height: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable var preferences: PreferencesStore
    let coordinator: AppCoordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Organization") {
                Toggle("Group session lists by repository", isOn: $preferences.value.groupByProject)
                Picker("Preferred terminal", selection: $preferences.value.preferredTerminal) {
                    ForEach(PreferredTerminal.allCases) { terminal in Text(terminal.displayName).tag(terminal) }
                }
                Picker("Automatically archive completed sessions", selection: $preferences.value.autoArchiveDays) {
                    Text("Never").tag(0)
                    Text("After 7 days").tag(7)
                    Text("After 30 days").tag(30)
                    Text("After 90 days").tag(90)
                }
                Toggle("Move failed sessions to Backlog", isOn: $preferences.value.backlogFailedSessions)
                Toggle("Move interrupted sessions to Backlog", isOn: $preferences.value.backlogInterruptedSessions)
            }
            Section("Startup and history") {
                Toggle("Launch Wildlife at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { old, new in if old != new { updateLaunchAtLogin(new) } }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                Button(coordinator.isImportingHistory ? "Loading history…" : "Load all older sessions") {
                    Task { await coordinator.importOlderHistory() }
                }
                .disabled(coordinator.isImportingHistory)
            }
        }
        .formStyle(.grouped)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct IntegrationSettings: View {
    @Bindable var preferences: PreferencesStore
    @Bindable var integrations: IntegrationManager

    var body: some View {
        Form {
            Section("Agent hooks") {
                ForEach(AgentProvider.allCases) { provider in
                    LabeledContent(provider.displayName) {
                        Label(stateLabel(provider), systemImage: stateIcon(provider))
                            .foregroundStyle(stateColor(provider))
                    }
                }
                HStack {
                    Button("Install or Repair") { Task { await integrations.installAll() } }
                    Button("Remove Hooks", role: .destructive) { Task { await integrations.uninstallAll() } }
                }
                .disabled(integrations.isWorking)
                if integrations.isWorking { ProgressView().controlSize(.small) }
                if let message = integrations.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = integrations.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Local agent homes") {
                TextField("Codex home", text: $preferences.value.codexHome)
                TextField("Claude home", text: $preferences.value.claudeHome)
                Button("Refresh Status") { Task { await integrations.refresh() } }
            }
            Section("Resume commands") {
                templateEditor("Codex", text: $preferences.value.codexResumeTemplate)
                templateEditor("Claude", text: $preferences.value.claudeResumeTemplate)
                Text("Available placeholders: {{session_id}} and {{cwd}}. Values are shell-quoted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await integrations.refresh() }
    }

    private func state(_ provider: AgentProvider) -> HookInstallationState {
        integrations.states[provider] ?? .notInstalled
    }

    private func stateLabel(_ provider: AgentProvider) -> String {
        switch state(provider) {
        case .installed: "Installed"
        case .needsRepair: "Repair needed"
        case .notInstalled: "Not installed"
        }
    }

    private func stateIcon(_ provider: AgentProvider) -> String {
        switch state(provider) {
        case .installed: "checkmark.circle.fill"
        case .needsRepair: "wrench.and.screwdriver.fill"
        case .notInstalled: "exclamationmark.circle"
        }
    }

    private func stateColor(_ provider: AgentProvider) -> Color {
        switch state(provider) {
        case .installed: .green
        case .needsRepair: .orange
        case .notInstalled: .secondary
        }
    }

    @ViewBuilder
    private func templateEditor(_ name: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            TextField("Resume template", text: text).font(.body.monospaced())
            if let error = validationError(text.wrappedValue) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func validationError(_ value: String) -> String? {
        do { try ResumeCommandTemplate.validate(value); return nil }
        catch { return error.localizedDescription }
    }
}

private struct NotificationSettings: View {
    @Bindable var preferences: PreferencesStore
    let coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("Attention notifications") {
                Toggle("Enable notifications", isOn: Binding(
                    get: { preferences.value.notifications.enabled },
                    set: { enabled in Task { await coordinator.setNotificationsEnabled(enabled) } }
                ))
                Group {
                    Toggle("Approvals", isOn: $preferences.value.notifications.approvals)
                    Toggle("Waiting for input", isOn: $preferences.value.notifications.input)
                    Toggle("Failures", isOn: $preferences.value.notifications.failures)
                    Toggle("Completions", isOn: $preferences.value.notifications.completions)
                }
                .disabled(!preferences.value.notifications.enabled)
                Text("Imported and replayed history never produces notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section("Local-only by design") {
                Label("No network client, telemetry, crash uploader, or updater", systemImage: "network.slash")
                Label("Hooks retain metadata only", systemImage: "doc.text.magnifyingglass")
                Label("Provider sessions and transcripts are read-only", systemImage: "lock.shield")
                Text("Removing a Wildlife record never removes its Codex or Claude session. Resume and termination actions always require confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct OnboardingView: View {
    @Bindable var preferences: PreferencesStore
    @Bindable var integrations: IntegrationManager
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("🦓").font(.system(size: 64))
            Text("Welcome to Wildlife").font(.largeTitle.bold())
            Text("Keep interactive Codex and Claude sessions visible without tying Wildlife to a particular terminal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            VStack(alignment: .leading, spacing: 12) {
                Label("Local lifecycle hooks register sessions automatically", systemImage: "terminal")
                Label("Only lifecycle and project metadata is retained", systemImage: "lock.shield")
                Label("Provider session data remains read-only", systemImage: "externaldrive.badge.checkmark")
            }
            .frame(maxWidth: 480, alignment: .leading)
            if let error = integrations.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Not Now") {
                    preferences.value.onboardingCompleted = true
                    dismiss()
                }
                Spacer()
                Button("Install Integrations") {
                    Task {
                        await integrations.installAll()
                        if integrations.errorMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(integrations.isWorking)
            }
        }
        .padding(32)
        .frame(width: 620)
    }
}
