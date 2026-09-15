import Foundation
import WildlifeDomain

private struct HookEventMetadata: Decodable {
    let sessionID: String
    let hookEventName: String
    let cwd: String?
    let model: String?
    let toolName: String?
    let source: String?
    let reason: String?
    let notificationType: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case model
        case toolName = "tool_name"
        case source
        case reason
        case notificationType = "notification_type"
    }
}

package enum AgentEventFactory {
    package static func decodeHookInput(
        _ data: Data,
        provider: AgentProvider,
        fallbackCWD: String,
        process: AgentProcessIdentity?
    ) throws -> AgentEvent {
        let metadata = try JSONDecoder().decode(HookEventMetadata.self, from: data)
        guard let kind = AgentEvent.Kind(rawValue: metadata.hookEventName) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported hook event"))
        }
        let event = AgentEvent(
            sessionID: SessionID(provider: provider, externalID: metadata.sessionID),
            kind: kind,
            cwd: nonempty(metadata.cwd) ?? fallbackCWD,
            process: process,
            model: nonempty(metadata.model),
            toolName: nonempty(metadata.toolName),
            startSource: nonempty(metadata.source),
            endReason: nonempty(metadata.reason),
            notificationType: nonempty(metadata.notificationType)
        )
        guard event.isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Hook metadata failed validation"))
        }
        return event
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
