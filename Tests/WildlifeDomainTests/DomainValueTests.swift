import Foundation
import Testing
@testable import WildlifeDomain

@Suite("Domain values")
struct DomainValueTests {
    @Test("Session keys are canonical and provider-qualified")
    func sessionID() throws {
        let value = SessionID(provider: .claude, externalID: "abc:def")
        #expect(value.description == "claude:abc:def")
        #expect(SessionID(key: value.description) == value)
        #expect(SessionID(key: "unknown:value") == nil)
        #expect(SessionID(key: "codex:") == nil)
    }

    @Test("Transport validation enforces provider event sets and bounded metadata")
    func eventValidation() {
        let process = AgentProcessIdentity(pid: 22, startIdentity: "start", tty: "/dev/ttys001")
        let codex = SessionID(provider: .codex, externalID: "one")
        #expect(AgentEvent(sessionID: codex, kind: .sessionStart, cwd: "/tmp", process: process).isValid)
        #expect(!AgentEvent(sessionID: codex, kind: .stopFailure, cwd: "/tmp", process: process).isValid)
        #expect(!AgentEvent(sessionID: codex, kind: .sessionStart, cwd: "/tmp", process: .init(pid: 1, startIdentity: "", tty: nil)).isValid)
        #expect(!AgentEvent(sessionID: codex, kind: .sessionStart, cwd: String(repeating: "x", count: 4_097), process: process).isValid)
    }

    @Test("Emoji validation accepts one rendered emoji only", arguments: [
        ("🦓", true), ("🐻‍❄️", true), ("🇩🇪", true), ("©️", true), ("1️⃣", true),
        ("🦓🦉", false), ("A", false), ("1", false), ("#", false), ("*", false), ("©", false),
    ])
    func emoji(value: String, expected: Bool) {
        #expect(EmojiAllocator.isSingleEmoji(value) == expected)
    }

    @Test("Resume templates validate placeholders and shell-quote values")
    func resumeTemplate() throws {
        let rendered = try ResumeCommandTemplate.render(
            "cd {{cwd}} && runner {{session_id}}",
            sessionID: "abc'def",
            cwd: "/tmp/My Project"
        )
        #expect(rendered == "cd '/tmp/My Project' && runner 'abc'\\''def'")
        #expect(throws: ResumeTemplateError.missingSessionID) {
            try ResumeCommandTemplate.validate("codex resume")
        }
        #expect(throws: ResumeTemplateError.unknownPlaceholder("{{prompt}}")) {
            try ResumeCommandTemplate.validate("codex resume {{session_id}} {{prompt}}")
        }
    }

    @Test("AppleScript text is escaped")
    func appleScriptEscaping() {
        let escaped = AppleScriptEscaper.stringLiteral("one\n\"two\" \\path")
        #expect(escaped.contains(#"\"two\""#))
        #expect(escaped.contains(#"\\path"#))
        #expect(escaped.contains(" & linefeed & "))
    }

    @Test("Notification decisions expose only user-relevant transitions")
    func notificationDecision() {
        let id = SessionID(provider: .claude, externalID: "notify")
        let approval = AgentEvent(sessionID: id, kind: .permissionRequest, cwd: "/tmp")
        let transition = SessionTransition(sessionID: id, event: approval, previousStatus: .processing, currentStatus: .waitingForApproval)
        #expect(SessionNotificationDecision.kind(for: transition) == .approval)
        let tool = AgentEvent(sessionID: id, kind: .preToolUse, cwd: "/tmp")
        #expect(SessionNotificationDecision.kind(for: .init(sessionID: id, event: tool, previousStatus: .processing, currentStatus: .runningTool)) == nil)
    }
}
