import Foundation

public enum ResumeTemplateError: LocalizedError, Equatable {
    case missingSessionID
    case unknownPlaceholder(String)

    public var errorDescription: String? {
        switch self {
        case .missingSessionID:
            "The template must contain {{session_id}}."
        case .unknownPlaceholder(let placeholder):
            "Unknown placeholder: \(placeholder)"
        }
    }
}

public enum ResumeCommandTemplate {
    public static let codexDefault = "cd {{cwd}} && codex resume {{session_id}}"
    public static let claudeDefault = "cd {{cwd}} && claude --resume {{session_id}}"

    public static func validate(_ template: String) throws {
        guard template.contains("{{session_id}}") else {
            throw ResumeTemplateError.missingSessionID
        }
        let regex = try NSRegularExpression(pattern: #"\{\{[^}]+\}\}"#)
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        for match in regex.matches(in: template, range: range) {
            guard let swiftRange = Range(match.range, in: template) else { continue }
            let token = String(template[swiftRange])
            if token != "{{session_id}}" && token != "{{cwd}}" {
                throw ResumeTemplateError.unknownPlaceholder(token)
            }
        }
    }

    public static func render(_ template: String, sessionID: String, cwd: String) throws -> String {
        try validate(template)
        return template
            .replacingOccurrences(of: "{{session_id}}", with: shellQuote(sessionID))
            .replacingOccurrences(of: "{{cwd}}", with: shellQuote(cwd))
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
