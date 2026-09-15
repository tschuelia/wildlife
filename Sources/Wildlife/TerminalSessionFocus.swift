import AppKit
import Foundation
import WildlifeDomain
import WildlifeInfrastructure

enum TerminalFocusResult: Equatable {
    case exactSession
    case owningApplication
    case unavailable(TerminalFocusFailure)
}

enum TerminalFocusFailure: Equatable {
    case processUnavailable
    case owningApplicationUnavailable
    case activationRejected(String)

    var message: String {
        switch self {
        case .processUnavailable:
            "The recorded agent process is no longer available."
        case .owningApplicationUnavailable:
            "Wildlife could not identify the terminal or IDE that owns this session."
        case let .activationRejected(name):
            "macOS did not allow Wildlife to focus \(name)."
        }
    }
}

@MainActor
final class TerminalSessionFocus {
    private enum BundleIdentifier {
        static let iTerm = "com.googlecode.iterm2"
        static let terminal = "com.apple.Terminal"
    }

    func focus(_ session: Session) -> TerminalFocusResult {
        guard let process = session.process,
              ProcessInspector.isAlive(pid: process.pid, startIdentity: process.startIdentity) else {
            return .unavailable(.processUnavailable)
        }
        guard let application = owningApplication(startingAt: process.pid) else {
            return .unavailable(.owningApplicationUnavailable)
        }

        prepareToActivate(application)
        switch application.bundleIdentifier {
        case BundleIdentifier.iTerm:
            if let tty = validatedTTY(process.tty), focusITerm(tty: tty) {
                return .exactSession
            }
        case BundleIdentifier.terminal:
            if let tty = validatedTTY(process.tty), focusTerminal(tty: tty) {
                return .exactSession
            }
        default:
            break
        }

        let name = application.localizedName ?? "the originating application"
        return activate(application)
            ? .owningApplication
            : .unavailable(.activationRejected(name))
    }

    private func owningApplication(startingAt processID: Int32) -> NSRunningApplication? {
        let wildlifeBundleIdentifier = Bundle.main.bundleIdentifier
        return ProcessInspector.ancestorProcessIDs(startingAt: processID)
            .compactMap(NSRunningApplication.init(processIdentifier:))
            .first { application in
                application.bundleIdentifier != wildlifeBundleIdentifier
                    && application.activationPolicy != .prohibited
            }
    }

    private func activate(_ application: NSRunningApplication) -> Bool {
        prepareToActivate(application)
        return application.activate(
            from: NSRunningApplication.current,
            options: [.activateAllWindows]
        )
    }

    private func prepareToActivate(_ application: NSRunningApplication) {
        if application.isHidden {
            _ = application.unhide()
        }
        NSApp.yieldActivation(to: application)
    }

    private func validatedTTY(_ tty: String?) -> String? {
        guard let tty,
              tty.range(of: #"^/dev/tty[[:alnum:]_.-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return tty
    }

    private func focusITerm(tty: String) -> Bool {
        executeAppleScript(
            """
            tell application id "com.googlecode.iterm2"
                repeat with terminalWindow in windows
                    repeat with terminalTab in tabs of terminalWindow
                        repeat with terminalSession in sessions of terminalTab
                            if tty of terminalSession is "\(tty)" then
                                set miniaturized of terminalWindow to false
                                select terminalSession
                                activate
                                return "focused"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "not-found"
            end tell
            """
        )
    }

    private func focusTerminal(tty: String) -> Bool {
        executeAppleScript(
            """
            tell application id "com.apple.Terminal"
                repeat with terminalWindow in windows
                    repeat with terminalTab in tabs of terminalWindow
                        if tty of terminalTab is "\(tty)" then
                            set selected tab of terminalWindow to terminalTab
                            set miniaturized of terminalWindow to false
                            set frontmost of terminalWindow to true
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
                return "not-found"
            end tell
            """
        )
    }

    private func executeAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.stringValue == "focused"
    }
}
