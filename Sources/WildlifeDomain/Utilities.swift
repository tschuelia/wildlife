import Foundation

package enum EmojiAllocator {
    package static let orderedPool = [
        "🦓", "🦊", "🦉", "🐘", "🦒", "🦦", "🐙", "🦜", "🐬", "🦁",
        "🐼", "🐺", "🦝", "🐢", "🦩", "🦔", "🐿️", "🦘", "🦬", "🐻‍❄️",
    ]

    package static func next(used: Set<String>) -> String {
        if let emoji = orderedPool.first(where: { !used.contains($0) }) { return emoji }
        var index = 1
        while used.contains("🐾\(index)") { index += 1 }
        return "🐾\(index)"
    }

    package static func isSingleEmoji(_ value: String) -> Bool {
        guard value.count == 1 else { return false }
        let scalars = value.unicodeScalars
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji })
    }
}

package enum ResumeTemplateError: LocalizedError, Equatable {
    case unknownPlaceholder(String)
    case missingSessionID

    package var errorDescription: String? {
        switch self {
        case .unknownPlaceholder(let placeholder): "Unknown placeholder: \(placeholder)"
        case .missingSessionID: "The resume template must contain {{session_id}}."
        }
    }
}

package enum ResumeCommandTemplate {
    package static let codexDefault = "cd {{cwd}} && codex resume {{session_id}}"
    package static let claudeDefault = "cd {{cwd}} && claude --resume {{session_id}}"

    package static func validate(_ template: String) throws {
        guard template.contains("{{session_id}}") else { throw ResumeTemplateError.missingSessionID }
        let pattern = #"\{\{[^}]+\}\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        for match in regex.matches(in: template, range: range) {
            guard let swiftRange = Range(match.range, in: template) else { continue }
            let token = String(template[swiftRange])
            if token != "{{session_id}}" && token != "{{cwd}}" {
                throw ResumeTemplateError.unknownPlaceholder(token)
            }
        }
    }

    package static func render(_ template: String, sessionID: String, cwd: String) throws -> String {
        try validate(template)
        return template
            .replacingOccurrences(of: "{{session_id}}", with: shellQuote(sessionID))
            .replacingOccurrences(of: "{{cwd}}", with: shellQuote(cwd))
    }

    package static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

package enum AppleScriptEscaper {
    package static func stringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let escaped = line.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            .joined(separator: " & linefeed & ")
    }
}
