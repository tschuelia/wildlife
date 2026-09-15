import AppKit
import Foundation
@preconcurrency import UserNotifications
import WildlifeCore

enum WildlifeNotificationAction: Sendable {
    case open
    case focus
    case snooze
}

@MainActor
final class AttentionNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private enum Identifier {
        static let attentionCategory = "WILDLIFE_ATTENTION"
        static let completionCategory = "WILDLIFE_COMPLETION"
        static let focus = "WILDLIFE_FOCUS"
        static let snooze = "WILDLIFE_SNOOZE"
        static let sessionKey = "sessionKey"
    }

    private let center = UNUserNotificationCenter.current()
    private var actionHandler: (@MainActor @Sendable (WildlifeNotificationAction, String) -> Void)?

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Identifier.attentionCategory,
                actions: [
                    UNNotificationAction(identifier: Identifier.focus, title: "Focus Terminal"),
                    UNNotificationAction(identifier: Identifier.snooze, title: "Snooze 1 Hour"),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Identifier.completionCategory,
                actions: [],
                intentIdentifiers: []
            ),
        ])
    }

    func configure(
        actionHandler: @escaping @MainActor @Sendable (WildlifeNotificationAction, String) -> Void
    ) {
        self.actionHandler = actionHandler
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func notify(
        transition: SessionTransition,
        session: SessionRecord,
        settings: AppSettings
    ) {
        guard settings.notificationsEnabled,
              let kind = SessionNotificationDecision.kind(for: transition),
              isEnabled(kind, settings: settings) else { return }

        if session.attentionReason() == nil {
            cancelSnooze(for: session.stableKey)
        }
        let content = content(for: kind, session: session)
        let request = UNNotificationRequest(
            identifier: "wildlife-live-\(kind.rawValue)-\(session.stableKey)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func scheduleSnooze(for session: SessionRecord, until date: Date) {
        guard let reason = session.unsnoozedAttentionReason else { return }
        cancelSnooze(for: session.stableKey)
        let content = UNMutableNotificationContent()
        content.title = session.displayTitle
        content.body = reason.displayName
        content.sound = .default
        content.categoryIdentifier = Identifier.attentionCategory
        content.userInfo = [Identifier.sessionKey: session.stableKey]
        let interval = max(1, date.timeIntervalSinceNow)
        center.add(UNNotificationRequest(
            identifier: snoozeIdentifier(session.stableKey),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        ))
    }

    func cancelSnooze(for sessionKey: String) {
        let identifier = snoozeIdentifier(sessionKey)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
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
        let key = response.notification.request.content.userInfo[Identifier.sessionKey] as? String
        let action: WildlifeNotificationAction
        switch response.actionIdentifier {
        case Identifier.focus: action = .focus
        case Identifier.snooze: action = .snooze
        default: action = .open
        }
        if let key {
            Task { @MainActor [weak self] in
                self?.actionHandler?(action, key)
            }
        }
        completionHandler()
    }

    private func isEnabled(_ kind: SessionNotificationKind, settings: AppSettings) -> Bool {
        switch kind {
        case .approval: settings.notificationApproval
        case .input: settings.notificationInput
        case .failure: settings.notificationFailure
        case .completion: settings.notificationCompletion
        }
    }

    private func content(for kind: SessionNotificationKind, session: SessionRecord) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = session.displayTitle
        content.body = switch kind {
        case .approval: "Waiting for approval"
        case .input: "Waiting for your input"
        case .failure: "The session needs attention"
        case .completion: "Session completed"
        }
        content.sound = kind == .completion ? nil : .default
        content.categoryIdentifier = kind == .completion
            ? Identifier.completionCategory
            : Identifier.attentionCategory
        content.userInfo = [Identifier.sessionKey: session.stableKey]
        return content
    }

    private func snoozeIdentifier(_ key: String) -> String {
        "wildlife-snooze-\(key)"
    }
}
