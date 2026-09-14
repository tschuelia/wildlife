import AppKit
import Foundation
import WildlifeCore

enum TerminalFocusResult: Equatable {
    case exactSession
    case owningApplication
    case unavailable

    var succeeded: Bool { self != .unavailable }
}

@MainActor
final class TerminalSessionFocus {
    private enum BundleIdentifier {
        static let iTerm = "com.googlecode.iterm2"
        static let terminal = "com.apple.Terminal"
    }

    func focus(_ session: SessionRecord) -> TerminalFocusResult {
        guard let processID = session.processID,
              ProcessInspector.isAlive(pid: processID, startIdentity: session.processStartIdentity),
              let application = owningApplication(startingAt: processID) else {
            return .unavailable
        }

        switch application.bundleIdentifier {
        case BundleIdentifier.iTerm:
            if let tty = validatedTTY(session.tty), focusITerm(tty: tty) {
                return .exactSession
            }
        case BundleIdentifier.terminal:
            if let tty = validatedTTY(session.tty), focusTerminal(tty: tty) {
                return .exactSession
            }
        default:
            break
        }

        return activate(application) ? .owningApplication : .unavailable
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
        if application.isHidden {
            application.unhide()
        }
        return application.activate(options: [.activateAllWindows])
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
