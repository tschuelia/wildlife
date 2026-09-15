import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }
    public var displayName: String { self == .codex ? "Codex" : "Claude" }
}

public enum WorkflowBucket: String, Codable, CaseIterable, Identifiable, Sendable {
    case inProgress
    case backlog
    case completed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inProgress: "In Progress"
        case .backlog: "Backlog"
        case .completed: "Completed"
        }
    }
}

public enum RuntimeStatus: String, Codable, CaseIterable, Sendable {
    case starting
    case processing
    case runningTool
    case waitingForApproval
    case compacting
    case waitingForInput
    case error
    case ended

    public var displayName: String {
        switch self {
        case .starting: "Starting"
        case .processing: "Processing"
        case .runningTool: "Running tool"
        case .waitingForApproval: "Waiting for approval"
        case .compacting: "Compacting"
        case .waitingForInput: "Waiting for input"
        case .error: "Needs attention"
        case .ended: "Ended"
        }
    }

    public var priority: Int {
        switch self {
        case .waitingForApproval, .error: 0
        case .processing, .runningTool, .compacting, .starting: 1
        case .waitingForInput: 2
        case .ended: 3
        }
    }
}

public final class SessionRecord: Codable, Identifiable {
    public var stableKey: String
    public var providerRaw: String
    public var sessionID: String
    public var sourceTitle: String
    public var customTitle: String?
    public var emoji: String
    public var emojiWasCustomized: Bool
    public var cwd: String
    public var createdAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    public var lastEventAt: Date
    public var lastEventID: String?
    public var isForkedSession: Bool
    public var workflowRaw: String
    public var runtimeRaw: String
    public var processID: Int32?
    public var processStartIdentity: String?
    public var processMissingSince: Date?
    public var tty: String?
    public var modelName: String?
    public var toolName: String?
    public var notesMarkdown: String
    public var backlogOrder: Double
    public var resumeCount: Int
    public var activeSubagentCount: Int
    public var projectMetadata: ProjectMetadata?
    public var activities: [SessionActivity]
    public var activitySummary: SessionActivitySummary
    public var tags: [String]
    public var isPinned: Bool
    public var archivedAt: Date?
    public var attentionSnoozedUntil: Date?
    public var lastTurnOutcome: SessionTurnOutcome?

    public init(
        provider: AgentProvider,
        sessionID: String,
        sourceTitle: String,
        emoji: String,
        cwd: String,
        createdAt: Date,
        updatedAt: Date,
        workflow: WorkflowBucket,
        runtimeStatus: RuntimeStatus,
        emojiWasCustomized: Bool = false
    ) {
        self.stableKey = "\(provider.rawValue):\(sessionID)"
        self.providerRaw = provider.rawValue
        self.sessionID = sessionID
        self.sourceTitle = sourceTitle
        self.emoji = emoji
        self.emojiWasCustomized = emojiWasCustomized
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEventAt = updatedAt
        self.isForkedSession = false
        self.workflowRaw = workflow.rawValue
        self.runtimeRaw = runtimeStatus.rawValue
        self.notesMarkdown = ""
        self.backlogOrder = updatedAt.timeIntervalSince1970
        self.resumeCount = 0
        self.activeSubagentCount = 0
        self.activities = []
        self.activitySummary = SessionActivitySummary()
        self.tags = []
        self.isPinned = false
    }

    private enum CodingKeys: String, CodingKey {
        case stableKey, providerRaw, sessionID, sourceTitle, customTitle, emoji, emojiWasCustomized, cwd
        case createdAt, updatedAt, endedAt, lastEventAt, lastEventID, isForkedSession, workflowRaw, runtimeRaw
        case processID, processStartIdentity, processMissingSince, tty, modelName, toolName
        case notesMarkdown, backlogOrder, resumeCount, activeSubagentCount
        case projectMetadata, activities, activitySummary, tags, isPinned, archivedAt
        case attentionSnoozedUntil, lastTurnOutcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerRaw = try container.decodeIfPresent(String.self, forKey: .providerRaw) ?? AgentProvider.codex.rawValue
        sessionID = try container.decode(String.self, forKey: .sessionID)
        stableKey = try container.decodeIfPresent(String.self, forKey: .stableKey) ?? "\(providerRaw):\(sessionID)"
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle) ?? ""
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "🐾"
        emojiWasCustomized = try container.decodeIfPresent(Bool.self, forKey: .emojiWasCustomized)
            ?? !EmojiAllocator.isAutomaticallyAllocated(emoji)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        lastEventAt = try container.decodeIfPresent(Date.self, forKey: .lastEventAt) ?? updatedAt
        lastEventID = try container.decodeIfPresent(String.self, forKey: .lastEventID)
        isForkedSession = try container.decodeIfPresent(Bool.self, forKey: .isForkedSession) ?? false
        workflowRaw = try container.decodeIfPresent(String.self, forKey: .workflowRaw) ?? WorkflowBucket.completed.rawValue
        runtimeRaw = try container.decodeIfPresent(String.self, forKey: .runtimeRaw) ?? RuntimeStatus.ended.rawValue
        processID = try container.decodeIfPresent(Int32.self, forKey: .processID)
        processStartIdentity = try container.decodeIfPresent(String.self, forKey: .processStartIdentity)
        processMissingSince = try container.decodeIfPresent(Date.self, forKey: .processMissingSince)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        notesMarkdown = try container.decodeIfPresent(String.self, forKey: .notesMarkdown) ?? ""
        backlogOrder = try container.decodeIfPresent(Double.self, forKey: .backlogOrder) ?? updatedAt.timeIntervalSince1970
        resumeCount = try container.decodeIfPresent(Int.self, forKey: .resumeCount) ?? 0
        activeSubagentCount = try container.decodeIfPresent(Int.self, forKey: .activeSubagentCount) ?? 0
        projectMetadata = try container.decodeIfPresent(ProjectMetadata.self, forKey: .projectMetadata)
        activities = try container.decodeIfPresent([SessionActivity].self, forKey: .activities) ?? []
        activitySummary = try container.decodeIfPresent(SessionActivitySummary.self, forKey: .activitySummary) ?? SessionActivitySummary()
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        attentionSnoozedUntil = try container.decodeIfPresent(Date.self, forKey: .attentionSnoozedUntil)
        lastTurnOutcome = try container.decodeIfPresent(SessionTurnOutcome.self, forKey: .lastTurnOutcome)
    }

    public var provider: AgentProvider {
        get { AgentProvider(rawValue: providerRaw) ?? .codex }
        set { providerRaw = newValue.rawValue }
    }

    public var workflow: WorkflowBucket {
        get { WorkflowBucket(rawValue: workflowRaw) ?? .completed }
        set { workflowRaw = newValue.rawValue }
    }

    public var runtimeStatus: RuntimeStatus {
        get { RuntimeStatus(rawValue: runtimeRaw) ?? .ended }
        set { runtimeRaw = newValue.rawValue }
    }

    public var displayTitle: String {
        let override = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        let source = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty { return source }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return folder.isEmpty ? provider.displayName : "\(folder) · \(provider.displayName)"
    }

    public var id: String { stableKey }
}

public struct ImportedSession: Sendable, Equatable {
    public let provider: AgentProvider
    public let sessionID: String
    public let title: String
    public let cwd: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        provider: AgentProvider,
        sessionID: String,
        title: String,
        cwd: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var stableKey: String { "\(provider.rawValue):\(sessionID)" }
}
