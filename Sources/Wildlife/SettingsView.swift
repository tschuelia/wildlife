import ServiceManagement
import SwiftUI
import WildlifeCore

struct WildlifeSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var integrations: IntegrationManager
    @ObservedObject var runtime: AppRuntime
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var importMessage: String?

    var body: some View {
        Form {
            Section("Agent integrations") {
                integrationRow("Codex", state: integrations.codexState)
                integrationRow("Claude", state: integrations.claudeState)
                HStack {
                    Button("Install or Repair") { integrations.installAll() }
                    Button("Remove Hooks", role: .destructive) { integrations.uninstallAll() }
                }
                if let message = integrations.lastMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = integrations.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Codex asks you to review new hooks with /hooks. Wildlife handlers are status-only and preserve other configured hooks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Local agent homes") {
                TextField("Codex home", text: $settings.codexHome)
                    .onSubmit { integrations.refresh() }
                TextField("Claude home", text: $settings.claudeHome)
                    .onSubmit { integrations.refresh() }
            }

            Section("Resume command templates") {
                templateEditor("Codex", template: $settings.codexResumeTemplate)
                templateEditor("Claude", template: $settings.claudeResumeTemplate)
                Text("Available placeholders: {{session_id}} and {{cwd}}. Values are safely shell-quoted when copied.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Enable attention notifications", isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { runtime.setNotificationsEnabled($0) }
                ))
                Group {
                    Toggle("Approvals", isOn: $settings.notificationApproval)
                    Toggle("Waiting for input", isOn: $settings.notificationInput)
                    Toggle("Failures", isOn: $settings.notificationFailure)
                    Toggle("Completions", isOn: $settings.notificationCompletion)
                }
                .disabled(!settings.notificationsEnabled)
                Text("Permission is requested only when notifications are enabled. Replayed and imported history stays silent.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Organization") {
                Toggle("Group lanes by repository", isOn: $settings.groupByProject)
                Picker("Preferred terminal", selection: $settings.preferredTerminal) {
                    ForEach(PreferredTerminal.allCases) { terminal in
                        Text(terminal.displayName).tag(terminal)
                    }
                }
                Picker("Automatically archive completed sessions", selection: $settings.autoArchiveDays) {
                    Text("Never").tag(0)
                    Text("After 7 days").tag(7)
                    Text("After 30 days").tag(30)
                    Text("After 90 days").tag(90)
                }
                Toggle("Move failed sessions to Backlog when they end", isOn: $settings.backlogFailedSessions)
                Toggle("Move interrupted sessions to Backlog when they end", isOn: $settings.backlogInterruptedSessions)
            }

            Section("Startup and history") {
                Toggle("Launch Wildlife at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        updateLaunchAtLogin(newValue)
                    }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                Button(runtime.isImportingOlderHistory ? "Loading older sessions…" : "Load all older sessions") {
                    runtime.importOlderHistory()
                    importMessage = "Older local indexes are being imported."
                }
                .disabled(runtime.isImportingOlderHistory)
                if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Privacy") {
                Text("Wildlife has no network client, telemetry, crash uploader, or updater. Hooks discard prompts and tool contents before sending metadata to the app. Removing a record never removes its agent transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 640, height: 780)
    }

    @ViewBuilder
    private func integrationRow(_ name: String, state: HookInstallationState) -> some View {
        LabeledContent(name) {
            switch state {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .needsRepair:
                Label("Repair needed", systemImage: "wrench.and.screwdriver.fill")
                    .foregroundStyle(.orange)
            case .notInstalled:
                Label("Not installed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func templateEditor(_ name: String, template: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            TextField("Resume template", text: template)
                .font(.body.monospaced())
            if let error = validationError(template.wrappedValue) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func validationError(_ template: String) -> String? {
        do { try ResumeCommandTemplate.validate(template); return nil }
        catch { return error.localizedDescription }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var integrations: IntegrationManager
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("🦓").font(.system(size: 64))
            Text("Welcome to Wildlife").font(.largeTitle.bold())
            Text("Keep every interactive Codex and Claude session visible without tying Wildlife to a particular terminal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            VStack(alignment: .leading, spacing: 12) {
                Label("Local lifecycle hooks register sessions automatically", systemImage: "terminal")
                Label("Only IDs, status, project, process, and tool names are retained", systemImage: "lock.shield")
                Label("The most recent 30 days of local history are imported", systemImage: "clock.arrow.circlepath")
            }
            .frame(maxWidth: 480, alignment: .leading)
            if let error = integrations.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Not Now") {
                    settings.onboardingCompleted = true
                    dismiss()
                }
                Spacer()
                Button("Install Integrations") {
                    integrations.installAll()
                    if integrations.lastError == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent)
            }
            Text("After installation, open /hooks once in Codex to review and trust Wildlife. Existing running sessions must be restarted or resumed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 620)
    }
}
