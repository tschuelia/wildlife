import Foundation
import WildlifeDomain
@preconcurrency import UserNotifications

enum WildlifeNotificationAction: Sendable {
    case open
    case focus
    case snooze
}

@MainActor
final class AttentionNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private enum Identifier {
        static let attention = "WILDLIFE_ATTENTION"
        static let completion = "WILDLIFE_COMPLETION"
        static let focus = "WILDLIFE_FOCUS"
        static let snooze = "WILDLIFE_SNOOZE"
        static let sessionID = "sessionID"
    }

    private let center = UNUserNotificationCenter.current()
    private var actionHandler: (@MainActor @Sendable (WildlifeNotificationAction, SessionID) -> Void)?

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Identifier.attention,
                actions: [
                    UNNotificationAction(identifier: Identifier.focus, title: "Focus Terminal"),
                    UNNotificationAction(identifier: Identifier.snooze, title: "Snooze 1 Hour"),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(identifier: Identifier.completion, actions: [], intentIdentifiers: []),
        ])
    }

    func configure(actionHandler: @escaping @MainActor @Sendable (WildlifeNotificationAction, SessionID) -> Void) {
        self.actionHandler = actionHandler
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func notify(
        transition: SessionTransition,
        session: Session,
        preferences: NotificationPreferences
    ) {
        guard preferences.enabled,
              let kind = SessionNotificationDecision.kind(for: transition),
              isEnabled(kind, preferences: preferences) else { return }
        let content = content(for: kind, session: session)
        center.add(UNNotificationRequest(
            identifier: "wildlife-live-\(kind.rawValue)-\(session.id)",
            content: content,
            trigger: nil
        ))
    }

    func scheduleSnooze(for session: Session, until date: Date) {
        guard let reason = session.unsnoozedAttentionReason else { return }
        cancelSnooze(for: session.id)
        let content = UNMutableNotificationContent()
        content.title = session.displayTitle
        content.body = reason.displayName
        content.sound = .default
        content.categoryIdentifier = Identifier.attention
        content.userInfo = [Identifier.sessionID: session.id.description]
        center.add(UNNotificationRequest(
            identifier: snoozeIdentifier(session.id),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        ))
    }

    func cancelSnooze(for sessionID: SessionID) {
        let id = snoozeIdentifier(sessionID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func cancelAllSnoozes() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo[Identifier.sessionID] as? String
        let action: WildlifeNotificationAction = switch response.actionIdentifier {
        case Identifier.focus: .focus
        case Identifier.snooze: .snooze
        default: .open
        }
        if let key, let id = SessionID(key: key) {
            Task { @MainActor [weak self] in self?.actionHandler?(action, id) }
        }
        completionHandler()
    }

    private func isEnabled(_ kind: SessionNotificationKind, preferences: NotificationPreferences) -> Bool {
        switch kind {
        case .approval: preferences.approvals
        case .input: preferences.input
        case .failure: preferences.failures
        case .completion: preferences.completions
        }
    }

    private func content(for kind: SessionNotificationKind, session: Session) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = session.displayTitle
        content.body = switch kind {
        case .approval: "Waiting for approval"
        case .input: "Waiting for your input"
        case .failure: "The session needs attention"
        case .completion: "Session completed"
        }
        content.sound = kind == .completion ? nil : .default
        content.categoryIdentifier = kind == .completion ? Identifier.completion : Identifier.attention
        content.userInfo = [Identifier.sessionID: session.id.description]
        return content
    }

    private func snoozeIdentifier(_ id: SessionID) -> String { "wildlife-snooze-\(id)" }
}
