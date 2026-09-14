import Combine
import Foundation
import WildlifeCore

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let codexHome = "codexHome"
        static let claudeHome = "claudeHome"
        static let codexResumeTemplate = "codexResumeTemplate"
        static let claudeResumeTemplate = "claudeResumeTemplate"
        static let initialImportCompleted = "initialImportCompleted"
        static let onboardingCompleted = "onboardingCompleted"
    }

    private let defaults: UserDefaults

    @Published var codexHome: String { didSet { defaults.set(codexHome, forKey: Key.codexHome) } }
    @Published var claudeHome: String { didSet { defaults.set(claudeHome, forKey: Key.claudeHome) } }
    @Published var codexResumeTemplate: String { didSet { defaults.set(codexResumeTemplate, forKey: Key.codexResumeTemplate) } }
    @Published var claudeResumeTemplate: String { didSet { defaults.set(claudeResumeTemplate, forKey: Key.claudeResumeTemplate) } }
    @Published var initialImportCompleted: Bool { didSet { defaults.set(initialImportCompleted, forKey: Key.initialImportCompleted) } }
    @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        codexHome = defaults.string(forKey: Key.codexHome) ?? "\(home)/.codex"
        claudeHome = defaults.string(forKey: Key.claudeHome) ?? "\(home)/.claude"
        codexResumeTemplate = defaults.string(forKey: Key.codexResumeTemplate) ?? ResumeCommandTemplate.codexDefault
        claudeResumeTemplate = defaults.string(forKey: Key.claudeResumeTemplate) ?? ResumeCommandTemplate.claudeDefault
        initialImportCompleted = defaults.bool(forKey: Key.initialImportCompleted)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
    }

    func template(for provider: AgentProvider) -> String {
        provider == .codex ? codexResumeTemplate : claudeResumeTemplate
    }

    func configURL(for provider: AgentProvider) -> URL {
        let home = provider == .codex ? codexHome : claudeHome
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(provider == .codex ? "hooks.json" : "settings.json")
    }
}
