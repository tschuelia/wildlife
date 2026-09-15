import Foundation

public enum SessionTurnOutcome: String, Codable, Sendable {
    case completed
    case interrupted
    case failed
}

public enum SessionAttentionReason: String, Codable, Sendable {
    case approval
    case input
    case failure

    public var displayName: String {
        switch self {
        case .approval: "Waiting for approval"
        case .input: "Waiting for input"
        case .failure: "Needs attention"
        }
    }
}

public struct SessionTransition: Sendable, Equatable {
    public let sessionKey: String
    public let event: BridgeEvent
    public let previousStatus: RuntimeStatus
    public let currentStatus: RuntimeStatus

    public init(
        sessionKey: String,
        event: BridgeEvent,
        previousStatus: RuntimeStatus,
        currentStatus: RuntimeStatus
    ) {
        self.sessionKey = sessionKey
        self.event = event
        self.previousStatus = previousStatus
        self.currentStatus = currentStatus
    }
}

public enum SessionNotificationKind: String, Codable, Sendable {
    case approval
    case input
    case failure
    case completion
}

public enum SessionNotificationDecision {
    public static func kind(for transition: SessionTransition) -> SessionNotificationKind? {
        switch transition.event.lifecycleEvent {
        case "PermissionRequest": return .approval
        case "Stop", "Interrupt": return .input
        case "Notification" where transition.event.notificationType == "idle_prompt": return .input
        case "PostToolUseFailure", "StopFailure": return .failure
        case "SessionEnd": return .completion
        default: return nil
        }
    }
}

public struct ProjectMetadata: Codable, Equatable, Sendable {
    public let repositoryRoot: String
    public let worktreeRoot: String
    public let gitCommonDirectory: String
    public let branch: String

    public init(repositoryRoot: String, worktreeRoot: String, gitCommonDirectory: String, branch: String) {
        self.repositoryRoot = repositoryRoot
        self.worktreeRoot = worktreeRoot
        self.gitCommonDirectory = gitCommonDirectory
        self.branch = branch
    }

    public var projectKey: String { gitCommonDirectory }
    public var displayName: String {
        URL(fileURLWithPath: repositoryRoot, isDirectory: true).lastPathComponent
    }
    public var worktreeName: String {
        URL(fileURLWithPath: worktreeRoot, isDirectory: true).lastPathComponent
    }
}

public struct SessionActivity: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let eventName: String
    public let statusRaw: String
    public let toolName: String?
    public let endReason: String?
    public let notificationType: String?
    public let subagentCount: Int

    public init(
        id: String,
        timestamp: Date,
        eventName: String,
        status: RuntimeStatus,
        toolName: String?,
        endReason: String?,
        notificationType: String?,
        subagentCount: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventName = eventName
        self.statusRaw = status.rawValue
        self.toolName = toolName
        self.endReason = endReason
        self.notificationType = notificationType
        self.subagentCount = subagentCount
    }

    public var status: RuntimeStatus { RuntimeStatus(rawValue: statusRaw) ?? .ended }
}

public struct SessionActivitySummary: Codable, Equatable, Sendable {
    public var activeDuration: TimeInterval
    public var waitingForInputDuration: TimeInterval
    public var waitingForApprovalDuration: TimeInterval
    public var toolCount: Int
    public var permissionCount: Int
    public var compactionCount: Int
    public var interruptionCount: Int
    public var failureCount: Int
    public var subagentCount: Int

    public init(
        activeDuration: TimeInterval = 0,
        waitingForInputDuration: TimeInterval = 0,
        waitingForApprovalDuration: TimeInterval = 0,
        toolCount: Int = 0,
        permissionCount: Int = 0,
        compactionCount: Int = 0,
        interruptionCount: Int = 0,
        failureCount: Int = 0,
        subagentCount: Int = 0
    ) {
        self.activeDuration = activeDuration
        self.waitingForInputDuration = waitingForInputDuration
        self.waitingForApprovalDuration = waitingForApprovalDuration
        self.toolCount = toolCount
        self.permissionCount = permissionCount
        self.compactionCount = compactionCount
        self.interruptionCount = interruptionCount
        self.failureCount = failureCount
        self.subagentCount = subagentCount
    }
}

public enum SessionActivityRecorder {
    public static let detailLimit = 500

    public static func record(
        _ event: BridgeEvent,
        previousStatus: RuntimeStatus,
        previousWorkflow: WorkflowBucket,
        previousEventAt: Date,
        in session: SessionRecord
    ) {
        var summary = session.activitySummary
        if previousWorkflow == .inProgress {
            addDuration(
                max(0, event.timestamp.timeIntervalSince(previousEventAt)),
                status: previousStatus,
                to: &summary
            )
        }

        switch event.lifecycleEvent {
        case "PreToolUse": summary.toolCount += 1
        case "PermissionRequest": summary.permissionCount += 1
        case "PreCompact": summary.compactionCount += 1
        case "Interrupt": summary.interruptionCount += 1
        case "PostToolUseFailure", "StopFailure": summary.failureCount += 1
        case "SubagentStart": summary.subagentCount += 1
        default: break
        }
        session.activitySummary = summary

        session.activities.append(SessionActivity(
            id: event.eventID,
            timestamp: event.timestamp,
            eventName: event.lifecycleEvent,
            status: session.runtimeStatus,
            toolName: event.toolName,
            endReason: event.endReason,
            notificationType: event.notificationType,
            subagentCount: session.activeSubagentCount
        ))
        if session.activities.count > detailLimit {
            session.activities.removeFirst(session.activities.count - detailLimit)
        }

        switch event.lifecycleEvent {
        case "SessionStart", "UserPromptSubmit": session.lastTurnOutcome = nil
        case "Interrupt": session.lastTurnOutcome = .interrupted
        case "PostToolUseFailure", "StopFailure": session.lastTurnOutcome = .failed
        case "Stop": session.lastTurnOutcome = .completed
        default: break
        }
    }

    public static func recordProcessEnd(at timestamp: Date, in session: SessionRecord) {
        var summary = session.activitySummary
        addDuration(max(0, timestamp.timeIntervalSince(session.lastEventAt)), status: session.runtimeStatus, to: &summary)
        session.activitySummary = summary
        session.activities.append(SessionActivity(
            id: "process-ended-\(UUID().uuidString)",
            timestamp: timestamp,
            eventName: "ProcessEnded",
            status: .ended,
            toolName: nil,
            endReason: "process_exited",
            notificationType: nil,
            subagentCount: 0
        ))
        if session.activities.count > detailLimit {
            session.activities.removeFirst(session.activities.count - detailLimit)
        }
    }

    private static func addDuration(
        _ duration: TimeInterval,
        status: RuntimeStatus,
        to summary: inout SessionActivitySummary
    ) {
        switch status {
        case .starting, .processing, .runningTool, .compacting:
            summary.activeDuration += duration
        case .waitingForInput:
            summary.waitingForInputDuration += duration
        case .waitingForApproval:
            summary.waitingForApprovalDuration += duration
        case .error, .ended:
            break
        }
    }
}

public enum SessionBuiltInView: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case attention
    case favorites
    case recent
    case archived

    public var id: String { "builtin:\(rawValue)" }
    public var displayName: String { rawValue.capitalized }
}

public struct SessionFilter: Codable, Equatable, Sendable {
    public var query: String
    public var providerRaws: [String]
    public var workflowRaws: [String]
    public var projectKeys: [String]
    public var tags: [String]
    public var recentDays: Int?
    public var pinnedOnly: Bool
    public var attentionOnly: Bool
    public var includeArchived: Bool
    public var archivedOnly: Bool

    public init(
        query: String = "",
        providerRaws: [String] = [],
        workflowRaws: [String] = [],
        projectKeys: [String] = [],
        tags: [String] = [],
        recentDays: Int? = nil,
        pinnedOnly: Bool = false,
        attentionOnly: Bool = false,
        includeArchived: Bool = false,
        archivedOnly: Bool = false
    ) {
        self.query = query
        self.providerRaws = providerRaws
        self.workflowRaws = workflowRaws
        self.projectKeys = projectKeys
        self.tags = tags
        self.recentDays = recentDays
        self.pinnedOnly = pinnedOnly
        self.attentionOnly = attentionOnly
        self.includeArchived = includeArchived
        self.archivedOnly = archivedOnly
    }

    public static func builtIn(_ view: SessionBuiltInView) -> SessionFilter {
        switch view {
        case .all: SessionFilter()
        case .attention: SessionFilter(attentionOnly: true)
        case .favorites: SessionFilter(pinnedOnly: true)
        case .recent: SessionFilter(recentDays: 7)
        case .archived: SessionFilter(includeArchived: true, archivedOnly: true)
        }
    }

    public func matches(_ session: SessionRecord, now: Date = Date()) -> Bool {
        if archivedOnly {
            guard session.archivedAt != nil else { return false }
        } else if !includeArchived, session.archivedAt != nil {
            return false
        }
        if pinnedOnly, !session.isPinned { return false }
        if attentionOnly, session.attentionReason(at: now) == nil { return false }
        if !providerRaws.isEmpty, !providerRaws.contains(session.providerRaw) { return false }
        if !workflowRaws.isEmpty, !workflowRaws.contains(session.workflowRaw) { return false }
        if !projectKeys.isEmpty, !projectKeys.contains(session.projectKey) { return false }
        if let recentDays {
            let cutoff = now.addingTimeInterval(-Double(recentDays) * 86_400)
            if session.updatedAt < cutoff { return false }
        }
        if !tags.isEmpty {
            let requested = Set(tags.map(TagNormalizer.normalize))
            let available = Set(session.tags.map(TagNormalizer.normalize))
            if requested.isDisjoint(with: available) { return false }
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedQuery.isEmpty {
            let values = [
                session.displayTitle, session.cwd, session.provider.displayName,
                session.sessionID, session.notesMarkdown, session.projectMetadata?.branch ?? "",
            ] + session.tags
            if !values.contains(where: { $0.lowercased().contains(normalizedQuery) }) { return false }
        }
        return true
    }
}

public struct SavedSessionView: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var filter: SessionFilter

    public init(id: String = UUID().uuidString, name: String, filter: SessionFilter) {
        self.id = id
        self.name = name
        self.filter = filter
    }
}

public struct OrganizationRules: Codable, Equatable, Sendable {
    public var autoArchiveAfterDays: Int?
    public var backlogFailedSessions: Bool
    public var backlogInterruptedSessions: Bool

    public init(
        autoArchiveAfterDays: Int? = nil,
        backlogFailedSessions: Bool = false,
        backlogInterruptedSessions: Bool = false
    ) {
        self.autoArchiveAfterDays = autoArchiveAfterDays
        self.backlogFailedSessions = backlogFailedSessions
        self.backlogInterruptedSessions = backlogInterruptedSessions
    }
}

public enum SessionOrganization {
    public static func shouldAutoArchive(
        _ session: SessionRecord,
        rules: OrganizationRules,
        now: Date
    ) -> Bool {
        guard let days = rules.autoArchiveAfterDays,
              days > 0,
              session.workflow == .completed,
              session.archivedAt == nil,
              !session.isPinned else { return false }
        return now.timeIntervalSince(session.endedAt ?? session.updatedAt) >= Double(days) * 86_400
    }

    public static func shouldMoveToBacklog(_ session: SessionRecord, rules: OrganizationRules) -> Bool {
        switch session.lastTurnOutcome {
        case .failed: rules.backlogFailedSessions
        case .interrupted: rules.backlogInterruptedSessions
        default: false
        }
    }

    public static func conflictingWorktreeKeys(in sessions: [SessionRecord]) -> Set<String> {
        let grouped = Dictionary(grouping: sessions.filter { $0.workflow == .inProgress }) {
            $0.projectMetadata?.worktreeRoot ?? ""
        }
        return Set(grouped.compactMap { key, records in
            !key.isEmpty && records.count > 1 ? key : nil
        })
    }
}

public enum TagNormalizer {
    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizeAll(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = normalize(value)
            return !normalized.isEmpty && seen.insert(normalized).inserted ? normalized : nil
        }.sorted()
    }
}

public enum AppleScriptEscaper {
    public static func stringLiteral(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let escaped = line
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            .joined(separator: " & linefeed & ")
    }
}

public struct GitProjectInspector: Sendable {
    public init() {}

    public func inspect(cwd: String) -> ProjectMetadata? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", cwd, "rev-parse", "--path-format=absolute",
            "--show-toplevel", "--git-common-dir", "--abbrev-ref", "HEAD",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        return Self.parse(output: output)
    }

    public static func parse(output: String) -> ProjectMetadata? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 3 else { return nil }
        let worktree = canonicalPath(lines[0])
        let common = canonicalPath(lines[1])
        let repositoryRoot = URL(fileURLWithPath: common).lastPathComponent == ".git"
            ? URL(fileURLWithPath: common).deletingLastPathComponent().path
            : worktree
        let branch = lines[2] == "HEAD" ? "Detached HEAD" : lines[2]
        return ProjectMetadata(
            repositoryRoot: canonicalPath(repositoryRoot),
            worktreeRoot: worktree,
            gitCommonDirectory: common,
            branch: branch
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

public extension SessionRecord {
    var projectKey: String {
        projectMetadata?.projectKey ?? URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
    }

    var projectDisplayName: String {
        projectMetadata?.displayName ?? URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
    }

    func attentionReason(at now: Date = Date()) -> SessionAttentionReason? {
        if let attentionSnoozedUntil, attentionSnoozedUntil > now { return nil }
        return unsnoozedAttentionReason
    }

    var unsnoozedAttentionReason: SessionAttentionReason? {
        switch runtimeStatus {
        case .waitingForApproval: return .approval
        case .waitingForInput: return .input
        case .error: return .failure
        default: return nil
        }
    }
}
