import Foundation

package enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    package var id: Self { self }
    package var displayName: String { self == .codex ? "Codex" : "Claude" }
}

package struct SessionID: Hashable, Codable, Identifiable, Sendable, CustomStringConvertible {
    package let provider: AgentProvider
    package let externalID: String

    package init(provider: AgentProvider, externalID: String) {
        self.provider = provider
        self.externalID = externalID
    }

    package init?(key: String) {
        guard let separator = key.firstIndex(of: ":"),
              let provider = AgentProvider(rawValue: String(key[..<separator])) else { return nil }
        let externalID = String(key[key.index(after: separator)...])
        guard !externalID.isEmpty else { return nil }
        self.init(provider: provider, externalID: externalID)
    }

    package var id: String { description }
    package var description: String { "\(provider.rawValue):\(externalID)" }
}

package enum WorkflowBucket: String, Codable, CaseIterable, Identifiable, Sendable {
    case inProgress
    case backlog
    case completed

    package var id: Self { self }

    package var displayName: String {
        switch self {
        case .inProgress: "In Progress"
        case .backlog: "Backlog"
        case .completed: "Completed"
        }
    }
}

package enum ActiveStatus: String, Codable, CaseIterable, Sendable {
    case starting
    case processing
    case runningTool
    case waitingForApproval
    case compacting
    case waitingForInput
    case error

    package var displayName: String {
        switch self {
        case .starting: "Starting"
        case .processing: "Processing"
        case .runningTool: "Running tool"
        case .waitingForApproval: "Waiting for approval"
        case .compacting: "Compacting"
        case .waitingForInput: "Waiting for input"
        case .error: "Needs attention"
        }
    }

    package var priority: Int {
        switch self {
        case .waitingForApproval, .error: 0
        case .processing, .runningTool, .compacting, .starting: 1
        case .waitingForInput: 2
        }
    }
}

package enum ActivityStatus: String, Codable, Sendable {
    case starting
    case processing
    case runningTool
    case waitingForApproval
    case compacting
    case waitingForInput
    case error
    case ended

    package init(_ status: ActiveStatus) {
        self = switch status {
        case .starting: .starting
        case .processing: .processing
        case .runningTool: .runningTool
        case .waitingForApproval: .waitingForApproval
        case .compacting: .compacting
        case .waitingForInput: .waitingForInput
        case .error: .error
        }
    }

    package var displayName: String {
        if self == .ended { return "Ended" }
        return ActiveStatus(rawValue: rawValue)?.displayName ?? "Ended"
    }
}

package enum SessionTurnOutcome: String, Codable, Sendable {
    case completed
    case interrupted
    case failed
}

package enum SessionAttentionReason: String, Codable, Sendable {
    case approval
    case input
    case failure

    package var displayName: String {
        switch self {
        case .approval: "Waiting for approval"
        case .input: "Waiting for input"
        case .failure: "Needs attention"
        }
    }
}

package struct ActiveSessionState: Codable, Equatable, Sendable {
    package var status: ActiveStatus
    package var processMissingSince: Date?

    package init(status: ActiveStatus, processMissingSince: Date? = nil) {
        self.status = status
        self.processMissingSince = processMissingSince
    }
}

package struct EndedSessionState: Codable, Equatable, Sendable {
    package var endedAt: Date

    package init(endedAt: Date) {
        self.endedAt = endedAt
    }
}

package enum SessionLifecycle: Codable, Equatable, Sendable {
    case active(ActiveSessionState)
    case backlog(EndedSessionState, order: Int)
    case completed(EndedSessionState)

    package var bucket: WorkflowBucket {
        switch self {
        case .active: .inProgress
        case .backlog: .backlog
        case .completed: .completed
        }
    }

    package var endedAt: Date? {
        switch self {
        case .active: nil
        case .backlog(let state, _), .completed(let state): state.endedAt
        }
    }

    package var activeState: ActiveSessionState? {
        guard case .active(let state) = self else { return nil }
        return state
    }

    package var backlogOrder: Int? {
        guard case .backlog(_, let order) = self else { return nil }
        return order
    }
}

package enum SessionEmoji: Codable, Equatable, Sendable {
    case automatic(String)
    case custom(String)
    case historical

    package var value: String {
        switch self {
        case .automatic(let value), .custom(let value): value
        case .historical: "↻"
        }
    }

    package var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

package struct AgentProcessIdentity: Codable, Equatable, Sendable {
    package let pid: Int32
    package let startIdentity: String
    package let tty: String?

    package init(pid: Int32, startIdentity: String, tty: String?) {
        self.pid = pid
        self.startIdentity = startIdentity
        self.tty = tty
    }
}

package struct ProjectMetadata: Codable, Equatable, Sendable {
    package let repositoryRoot: String
    package let worktreeRoot: String
    package let gitCommonDirectory: String
    package let branch: String

    package init(repositoryRoot: String, worktreeRoot: String, gitCommonDirectory: String, branch: String) {
        self.repositoryRoot = repositoryRoot
        self.worktreeRoot = worktreeRoot
        self.gitCommonDirectory = gitCommonDirectory
        self.branch = branch
    }

    package var projectKey: String { gitCommonDirectory }
    package var displayName: String { URL(fileURLWithPath: repositoryRoot).lastPathComponent }
    package var worktreeName: String { URL(fileURLWithPath: worktreeRoot).lastPathComponent }
}

package struct SessionActivity: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package let timestamp: Date
    package let event: AgentEvent.Kind
    package let status: ActivityStatus
    package let toolName: String?
    package let endReason: String?
    package let notificationType: String?
    package let subagentCount: Int
}

package struct SessionActivitySummary: Codable, Equatable, Sendable {
    package var activeDuration: TimeInterval = 0
    package var waitingForInputDuration: TimeInterval = 0
    package var waitingForApprovalDuration: TimeInterval = 0
    package var toolCount = 0
    package var permissionCount = 0
    package var compactionCount = 0
    package var interruptionCount = 0
    package var failureCount = 0
    package var subagentCount = 0

    package init() {}
}

package struct Session: Codable, Equatable, Identifiable, Sendable {
    package let id: SessionID
    package var sourceTitle: String
    package var customTitle: String?
    package var emoji: SessionEmoji
    package var cwd: String
    package var createdAt: Date
    package var updatedAt: Date
    package var lastEventAt: Date
    package var lastEventID: String?
    package var isForked: Bool
    package var lifecycle: SessionLifecycle
    package var process: AgentProcessIdentity?
    package var modelName: String?
    package var toolName: String?
    package var notes: String
    package var resumeCount: Int
    package var activeSubagentCount: Int
    package var project: ProjectMetadata?
    package var activities: [SessionActivity]
    package var activitySummary: SessionActivitySummary
    package var tags: [String]
    package var isPinned: Bool
    package var archivedAt: Date?
    package var attentionSnoozedUntil: Date?
    package var lastTurnOutcome: SessionTurnOutcome?

    package init(
        id: SessionID,
        sourceTitle: String,
        emoji: SessionEmoji,
        cwd: String,
        createdAt: Date,
        updatedAt: Date,
        lifecycle: SessionLifecycle
    ) {
        self.id = id
        self.sourceTitle = sourceTitle
        self.emoji = emoji
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEventAt = updatedAt
        self.isForked = false
        self.lifecycle = lifecycle
        self.notes = ""
        self.resumeCount = 0
        self.activeSubagentCount = 0
        self.activities = []
        self.activitySummary = SessionActivitySummary()
        self.tags = []
        self.isPinned = false
    }

    package var provider: AgentProvider { id.provider }
    package var workflow: WorkflowBucket { lifecycle.bucket }
    package var activeStatus: ActiveStatus? { lifecycle.activeState?.status }
    package var endedAt: Date? { lifecycle.endedAt }
    package var sessionID: String { id.externalID }

    package var displayTitle: String {
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let source = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty { return source }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return folder.isEmpty ? provider.displayName : "\(folder) · \(provider.displayName)"
    }

    package var projectKey: String {
        project?.projectKey ?? URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    package var projectDisplayName: String {
        project?.displayName ?? URL(fileURLWithPath: cwd).lastPathComponent
    }

    package var unsnoozedAttentionReason: SessionAttentionReason? {
        guard let status = activeStatus else { return nil }
        switch status {
        case .waitingForApproval: return .approval
        case .waitingForInput: return .input
        case .error: return .failure
        default: return nil
        }
    }

    package func attentionReason(at now: Date = Date()) -> SessionAttentionReason? {
        if let until = attentionSnoozedUntil, until > now { return nil }
        return unsnoozedAttentionReason
    }
}

package struct ImportedSession: Equatable, Sendable {
    package let id: SessionID
    package let title: String
    package let cwd: String
    package let createdAt: Date
    package let updatedAt: Date

    package init(provider: AgentProvider, sessionID: String, title: String, cwd: String, createdAt: Date, updatedAt: Date) {
        id = SessionID(provider: provider, externalID: sessionID)
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
