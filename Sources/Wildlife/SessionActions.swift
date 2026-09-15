import AppKit
import Combine
import Foundation
import WildlifeCore

@MainActor
final class SessionActionController: ObservableObject {
    private let repository: SessionRepository
    private let settings: AppSettings
    private let terminalFocus = TerminalSessionFocus()

    @Published var pendingResumeSessionKey: String?
    @Published var pendingTerminationSessionKey: String?
    @Published private(set) var terminationRequestedSessionKeys = Set<String>()
    @Published var message: String?

    init(repository: SessionRepository, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
    }

    @discardableResult
    func focus(_ session: SessionRecord) -> Bool {
        let result = terminalFocus.focus(session)
        guard case let .unavailable(failure) = result else {
            message = nil
            return true
        }
        message = failure.message
        NSSound.beep()
        return false
    }

    func revealRepository(_ session: SessionRecord) {
        let path = session.projectMetadata?.worktreeRoot ?? session.cwd
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func openInTerminal(_ session: SessionRecord) {
        let path = session.projectMetadata?.worktreeRoot ?? session.cwd
        _ = launch(command: "cd \(ResumeCommandTemplate.shellQuote(path))")
    }

    func copyPath(_ session: SessionRecord) {
        let path = session.projectMetadata?.worktreeRoot ?? session.cwd
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        message = "Path copied"
    }

    func requestResume(_ session: SessionRecord) {
        pendingResumeSessionKey = session.stableKey
    }

    func requestTermination(_ session: SessionRecord) {
        guard session.workflow == .inProgress else { return }
        guard !terminationRequestedSessionKeys.contains(session.stableKey) else {
            message = "Termination has already been requested."
            return
        }
        guard session.processID != nil,
              let identity = session.processStartIdentity,
              !identity.isEmpty else {
            message = "This session does not have enough verified process information to terminate it safely."
            NSSound.beep()
            return
        }
        pendingTerminationSessionKey = session.stableKey
    }

    func isTerminationRequested(_ session: SessionRecord) -> Bool {
        terminationRequestedSessionKeys.contains(session.stableKey)
    }

    func confirmTermination(_ session: SessionRecord) {
        pendingTerminationSessionKey = nil
        guard let current = repository.session(forKey: session.stableKey),
              current.workflow == .inProgress,
              let pid = current.processID else {
            message = "The session is no longer active."
            return
        }

        switch ProcessInspector.requestTermination(
            pid: pid,
            startIdentity: current.processStartIdentity
        ) {
        case .signaled:
            terminationRequestedSessionKeys.insert(current.stableKey)
            message = "Termination requested…"
            monitorTermination(
                sessionKey: current.stableKey,
                pid: pid,
                startIdentity: current.processStartIdentity
            )
        case .alreadyExited, .identityMismatch:
            completeObservedExit(
                sessionKey: current.stableKey,
                reason: "process_ended",
                message: "The session process had already exited."
            )
        case .identityUnavailable:
            message = "The process identity could not be verified, so no signal was sent."
            NSSound.beep()
        case .inspectionUnavailable:
            message = "The process could not be inspected, so no signal was sent."
            NSSound.beep()
        case .permissionDenied:
            message = "macOS denied permission to terminate this session."
            NSSound.beep()
        case let .failed(errorNumber):
            message = "The session could not be terminated (error \(errorNumber))."
            NSSound.beep()
        }
    }

    func renderedResumeCommand(for session: SessionRecord) throws -> String {
        try ResumeCommandTemplate.render(
            settings.template(for: session.provider),
            sessionID: session.sessionID,
            cwd: session.cwd
        )
    }

    @discardableResult
    func confirmResume(_ session: SessionRecord) -> Bool {
        do {
            let command = try renderedResumeCommand(for: session)
            pendingResumeSessionKey = nil
            if launch(command: command) { return true }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            message = "Terminal automation failed; the resume command was copied."
            return false
        } catch {
            pendingResumeSessionKey = nil
            message = error.localizedDescription
            return false
        }
    }

    private func launch(command: String) -> Bool {
        let literal = AppleScriptEscaper.stringLiteral(command)
        let source: String
        switch settings.preferredTerminal {
        case .terminal:
            source = """
            tell application id "com.apple.Terminal"
                activate
                do script \(literal)
            end tell
            """
        case .iTerm:
            source = """
            tell application id "com.googlecode.iterm2"
                activate
                create window with default profile
                tell current session of current window to write text \(literal)
            end tell
            """
        }
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    private func monitorTermination(
        sessionKey: String,
        pid: Int32,
        startIdentity: String?
    ) {
        let monitor = Task.detached(priority: .utility) { () -> ProcessLiveness in
            var lastResult = ProcessLiveness.matching
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                lastResult = ProcessInspector.liveness(pid: pid, startIdentity: startIdentity)
                if lastResult == .notRunning || lastResult == .identityMismatch {
                    return lastResult
                }
            }
            return lastResult
        }
        Task { @MainActor [weak self] in
            let result = await monitor.value
            guard let self else { return }
            switch result {
            case .notRunning, .identityMismatch:
                completeObservedExit(
                    sessionKey: sessionKey,
                    reason: "user_terminated",
                    message: "Session terminated."
                )
            case .matching, .unknown:
                terminationRequestedSessionKeys.remove(sessionKey)
                message = "The session did not exit after SIGTERM."
                NSSound.beep()
            }
        }
    }

    private func completeObservedExit(sessionKey: String, reason: String, message: String) {
        defer { terminationRequestedSessionKeys.remove(sessionKey) }
        guard let session = repository.session(forKey: sessionKey),
              session.workflow == .inProgress else {
            self.message = "The session has ended."
            return
        }
        let event = BridgeEvent(
            provider: session.provider,
            sessionID: session.sessionID,
            lifecycleEvent: "SessionEnd",
            timestamp: Date(),
            cwd: session.cwd,
            endReason: reason
        )
        _ = repository.consume(event, rules: settings.organizationRules)
        self.message = message
    }
}
