import Combine
import Foundation
import WildlifeCore

enum PreferredTerminal: String, CaseIterable, Identifiable {
    case terminal
    case iTerm

    var id: String { rawValue }
    var displayName: String { self == .terminal ? "Terminal" : "iTerm2" }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let codexHome = "codexHome"
        static let claudeHome = "claudeHome"
        static let codexResumeTemplate = "codexResumeTemplate"
        static let claudeResumeTemplate = "claudeResumeTemplate"
        static let initialImportCompleted = "initialImportCompleted"
        static let onboardingCompleted = "onboardingCompleted"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationApproval = "notificationApproval"
        static let notificationInput = "notificationInput"
        static let notificationFailure = "notificationFailure"
        static let notificationCompletion = "notificationCompletion"
        static let preferredTerminal = "preferredTerminal"
        static let groupByProject = "groupByProject"
        static let autoArchiveDays = "autoArchiveDays"
        static let backlogFailedSessions = "backlogFailedSessions"
        static let backlogInterruptedSessions = "backlogInterruptedSessions"
        static let savedSessionViews = "savedSessionViews"
        static let selectedSessionViewID = "selectedSessionViewID"
    }

    private let defaults: UserDefaults

    @Published var codexHome: String { didSet { defaults.set(codexHome, forKey: Key.codexHome) } }
    @Published var claudeHome: String { didSet { defaults.set(claudeHome, forKey: Key.claudeHome) } }
    @Published var codexResumeTemplate: String { didSet { defaults.set(codexResumeTemplate, forKey: Key.codexResumeTemplate) } }
    @Published var claudeResumeTemplate: String { didSet { defaults.set(claudeResumeTemplate, forKey: Key.claudeResumeTemplate) } }
    @Published var initialImportCompleted: Bool { didSet { defaults.set(initialImportCompleted, forKey: Key.initialImportCompleted) } }
    @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) } }
    @Published var notificationApproval: Bool { didSet { defaults.set(notificationApproval, forKey: Key.notificationApproval) } }
    @Published var notificationInput: Bool { didSet { defaults.set(notificationInput, forKey: Key.notificationInput) } }
    @Published var notificationFailure: Bool { didSet { defaults.set(notificationFailure, forKey: Key.notificationFailure) } }
    @Published var notificationCompletion: Bool { didSet { defaults.set(notificationCompletion, forKey: Key.notificationCompletion) } }
    @Published var preferredTerminal: PreferredTerminal {
        didSet { defaults.set(preferredTerminal.rawValue, forKey: Key.preferredTerminal) }
    }
    @Published var groupByProject: Bool { didSet { defaults.set(groupByProject, forKey: Key.groupByProject) } }
    @Published var autoArchiveDays: Int { didSet { defaults.set(autoArchiveDays, forKey: Key.autoArchiveDays) } }
    @Published var backlogFailedSessions: Bool { didSet { defaults.set(backlogFailedSessions, forKey: Key.backlogFailedSessions) } }
    @Published var backlogInterruptedSessions: Bool { didSet { defaults.set(backlogInterruptedSessions, forKey: Key.backlogInterruptedSessions) } }
    @Published var savedSessionViews: [SavedSessionView] {
        didSet { saveSavedViews() }
    }
    @Published var selectedSessionViewID: String {
        didSet { defaults.set(selectedSessionViewID, forKey: Key.selectedSessionViewID) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        codexHome = defaults.string(forKey: Key.codexHome) ?? "\(home)/.codex"
        claudeHome = defaults.string(forKey: Key.claudeHome) ?? "\(home)/.claude"
        codexResumeTemplate = defaults.string(forKey: Key.codexResumeTemplate) ?? ResumeCommandTemplate.codexDefault
        claudeResumeTemplate = defaults.string(forKey: Key.claudeResumeTemplate) ?? ResumeCommandTemplate.claudeDefault
        initialImportCompleted = defaults.bool(forKey: Key.initialImportCompleted)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        notificationApproval = Self.bool(defaults, key: Key.notificationApproval, default: true)
        notificationInput = Self.bool(defaults, key: Key.notificationInput, default: true)
        notificationFailure = Self.bool(defaults, key: Key.notificationFailure, default: true)
        notificationCompletion = Self.bool(defaults, key: Key.notificationCompletion, default: true)
        preferredTerminal = PreferredTerminal(
            rawValue: defaults.string(forKey: Key.preferredTerminal) ?? ""
        ) ?? .terminal
        groupByProject = Self.bool(defaults, key: Key.groupByProject, default: true)
        autoArchiveDays = defaults.integer(forKey: Key.autoArchiveDays)
        backlogFailedSessions = defaults.bool(forKey: Key.backlogFailedSessions)
        backlogInterruptedSessions = defaults.bool(forKey: Key.backlogInterruptedSessions)
        if let data = defaults.data(forKey: Key.savedSessionViews),
           let views = try? JSONDecoder().decode([SavedSessionView].self, from: data) {
            savedSessionViews = views
        } else {
            savedSessionViews = []
        }
        selectedSessionViewID = defaults.string(forKey: Key.selectedSessionViewID)
            ?? SessionBuiltInView.all.id
    }

    func template(for provider: AgentProvider) -> String {
        provider == .codex ? codexResumeTemplate : claudeResumeTemplate
    }

    func configURL(for provider: AgentProvider) -> URL {
        let home = provider == .codex ? codexHome : claudeHome
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(provider == .codex ? "hooks.json" : "settings.json")
    }

    var organizationRules: OrganizationRules {
        OrganizationRules(
            autoArchiveAfterDays: autoArchiveDays > 0 ? autoArchiveDays : nil,
            backlogFailedSessions: backlogFailedSessions,
            backlogInterruptedSessions: backlogInterruptedSessions
        )
    }

    func filter(for viewID: String) -> SessionFilter {
        if let builtIn = SessionBuiltInView.allCases.first(where: { $0.id == viewID }) {
            return .builtIn(builtIn)
        }
        return savedSessionViews.first(where: { $0.id == viewID })?.filter ?? .builtIn(.all)
    }

    func saveView(name: String, filter: SessionFilter) -> SavedSessionView? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let view = SavedSessionView(name: trimmed, filter: filter)
        savedSessionViews.append(view)
        selectedSessionViewID = view.id
        return view
    }

    func deleteView(id: String) {
        savedSessionViews.removeAll { $0.id == id }
        if selectedSessionViewID == id { selectedSessionViewID = SessionBuiltInView.all.id }
    }

    private func saveSavedViews() {
        if let data = try? JSONEncoder().encode(savedSessionViews) {
            defaults.set(data, forKey: Key.savedSessionViews)
        }
    }

    private static func bool(_ defaults: UserDefaults, key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}
