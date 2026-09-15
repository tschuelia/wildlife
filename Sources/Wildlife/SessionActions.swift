import AppKit
import Foundation
import Observation
import WildlifeDomain
import WildlifeInfrastructure

@MainActor
@Observable
final class SessionActionController {
    private let library: SessionLibrary
    private let preferences: PreferencesStore
    private let terminalFocus = TerminalSessionFocus()
    private var terminationTasks: [SessionID: Task<Void, Never>] = [:]

    var pendingResumeSessionID: SessionID?
    var pendingTerminationSessionID: SessionID?
    private(set) var terminatingSessionIDs = Set<SessionID>()
    var message: String?

    init(library: SessionLibrary, preferences: PreferencesStore) {
        self.library = library
        self.preferences = preferences
    }

    @discardableResult
    func focus(_ session: Session) -> Bool {
        let result = terminalFocus.focus(session)
        guard case .unavailable(let failure) = result else {
            message = nil
            return true
        }
        message = failure.message
        NSSound.beep()
        return false
    }

    func revealProject(_ session: Session) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath(session))
    }

    func openProjectInTerminal(_ session: Session) {
        _ = launch(command: "cd \(ResumeCommandTemplate.shellQuote(projectPath(session)))")
    }

    func copyProjectPath(_ session: Session) {
        copy(projectPath(session))
        message = "Path copied"
    }

    func copySessionID(_ session: Session) {
        copy(session.sessionID)
        message = "Session ID copied"
    }

    func copyResumeCommand(_ session: Session) {
        do {
            copy(try renderedResumeCommand(for: session))
            message = "Resume command copied"
        } catch {
            message = error.localizedDescription
        }
    }

    func requestResume(_ session: Session) {
        pendingResumeSessionID = session.id
    }

    func requestTermination(_ session: Session) {
        guard session.workflow == .inProgress else { return }
        guard !terminatingSessionIDs.contains(session.id) else {
            message = "Termination has already been requested."
            return
        }
        guard let process = session.process, !process.startIdentity.isEmpty else {
            message = "This session does not have enough verified process information to terminate it safely."
            NSSound.beep()
            return
        }
        pendingTerminationSessionID = session.id
    }

    func renderedResumeCommand(for session: Session) throws -> String {
        try ResumeCommandTemplate.render(
            preferences.value.resumeTemplate(for: session.provider),
            sessionID: session.sessionID,
            cwd: session.cwd
        )
    }

    func confirmResume(_ id: SessionID) {
        pendingResumeSessionID = nil
        guard let session = library.session(id) else {
            message = "The session is no longer available."
            return
        }
        do {
            let command = try renderedResumeCommand(for: session)
            if launch(command: command) { return }
            copy(command)
            message = "Terminal automation failed; the resume command was copied."
        } catch {
            message = error.localizedDescription
        }
    }

    func confirmTermination(_ id: SessionID) {
        pendingTerminationSessionID = nil
        guard let session = library.session(id), session.workflow == .inProgress, let process = session.process else {
            message = "The session is no longer active."
            return
        }
        switch ProcessInspector.requestTermination(pid: process.pid, startIdentity: process.startIdentity) {
        case .signaled:
            terminatingSessionIDs.insert(id)
            message = "Termination requested…"
            monitorTermination(sessionID: id, process: process)
        case .alreadyExited, .identityMismatch:
            completeObservedExit(sessionID: id, reason: "process_ended", message: "The session process had already exited.")
        case .identityUnavailable:
            reportFailure("The process identity could not be verified, so no signal was sent.")
        case .inspectionUnavailable:
            reportFailure("The process could not be inspected, so no signal was sent.")
        case .permissionDenied:
            reportFailure("macOS denied permission to terminate this session.")
        case .failed(let number):
            reportFailure("The session could not be terminated (error \(number)).")
        }
    }

    private func monitorTermination(sessionID: SessionID, process: AgentProcessIdentity) {
        terminationTasks[sessionID]?.cancel()
        terminationTasks[sessionID] = Task { [weak self] in
            var result = ProcessLiveness.matching
            for _ in 0..<20 {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                result = await Task.detached(priority: .utility) { ProcessInspector.liveness(process) }.value
                if result == .notRunning || result == .identityMismatch { break }
            }
            guard let self else { return }
            self.terminationTasks[sessionID] = nil
            if result == .notRunning || result == .identityMismatch {
                self.completeObservedExit(sessionID: sessionID, reason: "user_terminated", message: "Session terminated.")
            } else {
                self.terminatingSessionIDs.remove(sessionID)
                self.reportFailure("The session did not exit after SIGTERM.")
            }
        }
    }

    private func completeObservedExit(sessionID: SessionID, reason: String, message: String) {
        terminatingSessionIDs.remove(sessionID)
        guard let session = library.session(sessionID), session.workflow == .inProgress else {
            self.message = "The session has ended."
            return
        }
        let event = AgentEvent(
            sessionID: session.id,
            kind: .sessionEnd,
            timestamp: Date(),
            cwd: session.cwd,
            endReason: reason
        )
        Task {
            _ = await library.consume(event, rules: preferences.value.organizationRules)
            self.message = message
        }
    }

    private func launch(command: String) -> Bool {
        let literal = AppleScriptEscaper.stringLiteral(command)
        let source = switch preferences.value.preferredTerminal {
        case .terminal:
            """
            tell application id "com.apple.Terminal"
                activate
                do script \(literal)
            end tell
            """
        case .iTerm:
            """
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

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func projectPath(_ session: Session) -> String {
        session.project?.worktreeRoot ?? session.cwd
    }

    private func reportFailure(_ value: String) {
        message = value
        NSSound.beep()
    }
}
