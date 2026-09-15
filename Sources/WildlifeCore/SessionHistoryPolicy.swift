import Foundation

package enum SessionHistoryPolicy {
    package static let defaultWindowDays = 7
    package static let completedEmojiRetentionInterval: TimeInterval = 3_600
    package static let historicalEmoji = "↻"

    package static func cutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(defaultWindowDays) * 86_400)
    }

    package static func isVisibleByDefault(_ session: SessionRecord, now: Date = Date()) -> Bool {
        session.workflow == .inProgress || session.updatedAt >= cutoff(now: now)
    }

    package static func shouldReleaseAutomaticEmoji(
        for session: SessionRecord,
        now: Date = Date()
    ) -> Bool {
        guard session.workflow == .completed,
              !session.emojiWasCustomized else { return false }
        guard let endedAt = session.endedAt else { return true }
        return now.timeIntervalSince(endedAt) >= completedEmojiRetentionInterval
    }

    package static func reservedEmojis(
        in sessions: [SessionRecord],
        now: Date = Date()
    ) -> Set<String> {
        Set(sessions.compactMap { session in
            guard session.emoji != historicalEmoji,
                  !shouldReleaseAutomaticEmoji(for: session, now: now) else { return nil }
            return session.emoji
        })
    }

    @discardableResult
    package static func releaseOldAutomaticEmojis(
        in sessions: [SessionRecord],
        now: Date = Date()
    ) -> Int {
        var count = 0
        for session in sessions where shouldReleaseAutomaticEmoji(for: session, now: now) {
            guard session.emoji != historicalEmoji else { continue }
            session.emoji = historicalEmoji
            count += 1
        }
        return count
    }
}
