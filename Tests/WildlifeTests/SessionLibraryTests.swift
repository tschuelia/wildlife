import Foundation
import Testing
@testable import Wildlife
import WildlifeDomain
import WildlifeInfrastructure

@MainActor
@Suite("Session library customization")
struct SessionLibraryTests {
    @Test("User-selected emojis may be duplicated")
    func duplicateCustomEmoji() async throws {
        let firstID = SessionID(provider: .codex, externalID: "first")
        let secondID = SessionID(provider: .claude, externalID: "second")
        let database = try SessionDatabase(url: nil)
        let original = SessionCollection(sessions: [session(firstID, emoji: "🦓"), session(secondID, emoji: "🦉")])
        try await database.apply(previous: SessionCollection(), next: original)
        let library = SessionLibrary(database: database)
        await library.load()

        #expect(await library.updateEmoji("🦊", sessionID: firstID) == nil)
        #expect(await library.updateEmoji("🦊", sessionID: secondID) == nil)
        #expect(library.session(firstID)?.emoji == .custom("🦊"))
        #expect(library.session(secondID)?.emoji == .custom("🦊"))

        let reloaded = SessionLibrary(database: database)
        await reloaded.load()
        #expect(reloaded.session(firstID)?.emoji == .custom("🦊"))
        #expect(reloaded.session(secondID)?.emoji == .custom("🦊"))
    }

    private func session(_ id: SessionID, emoji: String) -> Session {
        Session(
            id: id,
            sourceTitle: id.externalID,
            emoji: .automatic(emoji),
            cwd: "/tmp/project",
            createdAt: .now,
            updatedAt: .now,
            lifecycle: .completed(EndedSessionState(endedAt: .now))
        )
    }
}
