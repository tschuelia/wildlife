import Foundation

package struct AgentEvent: Codable, Equatable, Sendable {
    package static let schemaVersion = 1

    package enum Kind: String, Codable, CaseIterable, Sendable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case permissionDenied = "PermissionDenied"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case preCompact = "PreCompact"
        case postCompact = "PostCompact"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case notification = "Notification"
        case stop = "Stop"
        case interrupt = "Interrupt"
        case stopFailure = "StopFailure"
    }

    package let schema: Int
    package let id: String
    package let sessionID: SessionID
    package let kind: Kind
    package let timestamp: Date
    package let cwd: String
    package let process: AgentProcessIdentity?
    package let model: String?
    package let toolName: String?
    package let startSource: String?
    package let endReason: String?
    package let notificationType: String?

    package init(
        schema: Int = AgentEvent.schemaVersion,
        id: String = UUID().uuidString,
        sessionID: SessionID,
        kind: Kind,
        timestamp: Date = Date(),
        cwd: String,
        process: AgentProcessIdentity? = nil,
        model: String? = nil,
        toolName: String? = nil,
        startSource: String? = nil,
        endReason: String? = nil,
        notificationType: String? = nil
    ) {
        self.schema = schema
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.timestamp = timestamp
        self.cwd = cwd
        self.process = process
        self.model = model
        self.toolName = toolName
        self.startSource = startSource
        self.endReason = endReason
        self.notificationType = notificationType
    }

    package var isValid: Bool {
        guard schema == Self.schemaVersion,
              UUID(uuidString: id) != nil,
              !sessionID.externalID.isEmpty,
              sessionID.externalID.utf8.count <= 1_024,
              cwd.utf8.count <= 4_096,
              process.map({ $0.pid > 1 }) ?? true,
              Self.kinds(for: sessionID.provider).contains(kind) else { return false }
        return [process?.startIdentity, process?.tty, model, toolName, startSource, endReason, notificationType]
            .compactMap { $0 }
            .allSatisfy { $0.utf8.count <= 1_024 }
    }

    package static func kinds(for provider: AgentProvider) -> [Kind] {
        switch provider {
        case .codex:
            [.sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .permissionRequest,
             .postToolUse, .preCompact, .postCompact, .subagentStart, .subagentStop, .stop, .interrupt]
        case .claude:
            [.sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .permissionRequest,
             .permissionDenied, .postToolUse, .postToolUseFailure, .preCompact, .postCompact,
             .subagentStart, .subagentStop, .notification, .stop, .stopFailure]
        }
    }
}

package enum SessionNotificationKind: String, Codable, Sendable {
    case approval
    case input
    case failure
    case completion
}

package struct SessionTransition: Equatable, Sendable {
    package let sessionID: SessionID
    package let event: AgentEvent
    package let previousStatus: ActiveStatus?
    package let currentStatus: ActiveStatus?
}

package enum SessionNotificationDecision {
    package static func kind(for transition: SessionTransition) -> SessionNotificationKind? {
        switch transition.event.kind {
        case .permissionRequest: .approval
        case .stop, .interrupt: .input
        case .notification where transition.event.notificationType == "idle_prompt": .input
        case .postToolUseFailure, .stopFailure: .failure
        case .sessionEnd: .completion
        default: nil
        }
    }
}
