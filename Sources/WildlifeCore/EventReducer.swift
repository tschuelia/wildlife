import Foundation

public enum SessionEventReducer {
    @discardableResult
    public static func apply(_ event: BridgeEvent, to session: SessionRecord) -> Bool {
        guard event.schemaVersion == BridgeEvent.currentSchemaVersion else { return false }
        guard event.eventID != session.lastEventID else { return false }
        guard event.timestamp >= session.lastEventAt else { return false }

        let wasTerminated = session.workflow != .inProgress
        session.lastEventID = event.eventID
        session.lastEventAt = event.timestamp
        session.updatedAt = event.timestamp
        if !event.cwd.isEmpty { session.cwd = event.cwd }
        session.processID = event.processID ?? session.processID
        session.processStartIdentity = event.processStartIdentity ?? session.processStartIdentity
        session.tty = event.tty ?? session.tty
        session.modelName = event.model ?? session.modelName

        switch event.lifecycleEvent {
        case "SessionStart":
            if event.startSource == "resume", wasTerminated { session.resumeCount += 1 }
            session.workflow = .inProgress
            session.runtimeStatus = .waitingForInput
            session.endedAt = nil
            session.processMissingSince = nil
        case "UserPromptSubmit":
            session.workflow = .inProgress
            session.runtimeStatus = .processing
            session.toolName = nil
        case "PreToolUse":
            session.runtimeStatus = .runningTool
            session.toolName = event.toolName
        case "PermissionRequest":
            session.runtimeStatus = .waitingForApproval
            session.toolName = event.toolName
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied", "PostCompact":
            session.runtimeStatus = .processing
            session.toolName = event.toolName
        case "PreCompact":
            session.runtimeStatus = .compacting
            session.toolName = nil
        case "SubagentStart":
            session.activeSubagentCount += 1
            session.runtimeStatus = .processing
        case "SubagentStop":
            session.activeSubagentCount = max(0, session.activeSubagentCount - 1)
            session.runtimeStatus = .processing
        case "Stop", "Interrupt":
            session.runtimeStatus = .waitingForInput
            session.toolName = nil
        case "Notification":
            if event.notificationType == "idle_prompt" {
                session.runtimeStatus = .waitingForInput
            }
        case "StopFailure":
            session.runtimeStatus = .error
            session.toolName = nil
        case "SessionEnd":
            session.runtimeStatus = .ended
            session.workflow = .completed
            session.endedAt = event.timestamp
            session.processMissingSince = nil
            session.activeSubagentCount = 0
            session.toolName = nil
        default:
            return false
        }
        return true
    }
}
