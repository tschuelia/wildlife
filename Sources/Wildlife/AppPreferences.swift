import Foundation
import Observation
import WildlifeDomain

enum PreferredTerminal: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal
    case iTerm

    var id: Self { self }
    var displayName: String { self == .terminal ? "Terminal" : "iTerm2" }
}

struct NotificationPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var approvals = true
    var input = true
    var failures = true
    var completions = true
}

struct AppPreferences: Codable, Equatable, Sendable {
    var codexHome: String
    var claudeHome: String
    var codexResumeTemplate = ResumeCommandTemplate.codexDefault
    var claudeResumeTemplate = ResumeCommandTemplate.claudeDefault
    var notifications = NotificationPreferences()
    var preferredTerminal = PreferredTerminal.terminal
    var groupByProject = true
    var autoArchiveDays = 0
    var backlogFailedSessions = false
    var backlogInterruptedSessions = false
    var onboardingCompleted = false

    static func defaults(home: String) -> AppPreferences {
        AppPreferences(codexHome: "\(home)/.codex", claudeHome: "\(home)/.claude")
    }

    var organizationRules: OrganizationRules {
        OrganizationRules(
            autoArchiveAfterDays: autoArchiveDays > 0 ? autoArchiveDays : nil,
            backlogFailedSessions: backlogFailedSessions,
            backlogInterruptedSessions: backlogInterruptedSessions
        )
    }

    func resumeTemplate(for provider: AgentProvider) -> String {
        provider == .codex ? codexResumeTemplate : claudeResumeTemplate
    }

    func configURL(for provider: AgentProvider) -> URL {
        let home = provider == .codex ? codexHome : claudeHome
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(provider == .codex ? "hooks.json" : "settings.json")
    }
}

@MainActor
@Observable
final class PreferencesStore {
    private static let key = "preferences"
    private let defaults: UserDefaults

    var value: AppPreferences {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            value = decoded
        } else {
            value = .defaults(home: FileManager.default.homeDirectoryForCurrentUser.path)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
