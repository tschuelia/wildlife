import Foundation
import Testing
@testable import WildlifeDomain

@Suite("Session organization")
struct SessionQueryTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Filters compose with transient search")
    func combinedSearch() {
        var matching = session(.codex, "match", title: "Release API", age: 100, workflow: .completed)
        matching.tags = TagNormalizer.normalizeAll([" Urgent ", "urgent", "Backend"])
        matching.isPinned = true
        let wrongProvider = session(.claude, "other", title: "Release API", age: 100, workflow: .completed)
        let wrongQuery = session(.codex, "query", title: "Other work", age: 100, workflow: .completed)
        let filter = SessionFilter(
            query: "release",
            providers: [.codex],
            tags: ["urgent"],
            pinnedOnly: true
        )

        let result = SessionQuery.run(
            sessions: [matching, wrongProvider, wrongQuery],
            filter: filter,
            searchText: "backend",
            includeOlder: true,
            now: now
        )
        #expect(result.sessions.map(\.id) == [matching.id])
        #expect(matching.tags == ["backend", "urgent"])
    }

    @Test("Default history retains old active sessions but hides old completed sessions")
    func defaultHistory() {
        let active = session(.codex, "active", title: "Active", age: 30 * 86_400, workflow: .inProgress)
        let old = session(.codex, "old", title: "Old", age: 30 * 86_400, workflow: .completed)
        let recent = session(.codex, "recent", title: "Recent", age: 60, workflow: .completed)
        let result = SessionQuery.run(
            sessions: [old, recent, active],
            filter: SessionFilter(),
            searchText: "",
            includeOlder: false,
            now: now
        )
        #expect(Set(result.sessions.map(\.id)) == [active.id, recent.id])
    }

    @Test("Archived, attention, project, and tag filters are typed")
    func typedFilters() {
        var value = session(.claude, "one", title: "One", age: 10, workflow: .inProgress)
        value.tags = ["backend"]
        value.lifecycle = .active(ActiveSessionState(status: .waitingForInput))
        #expect(SessionFilter(attentionOnly: true).matches(value, now: now))
        value.attentionSnoozedUntil = now.addingTimeInterval(60)
        #expect(!SessionFilter(attentionOnly: true).matches(value, now: now))
        value.archivedAt = now
        #expect(!SessionFilter().matches(value, now: now))
        #expect(SessionFilter(includeArchived: true, archivedOnly: true).matches(value, now: now))
        #expect(SessionFilter(projectKeys: [value.projectKey], tags: ["backend"], includeArchived: true).matches(value, now: now))
    }

    @Test("Worktree conflicts include only concurrent active sessions")
    func conflicts() {
        let project = ProjectMetadata(
            repositoryRoot: "/tmp/repository",
            worktreeRoot: "/tmp/worktree",
            gitCommonDirectory: "/tmp/repository/.git",
            branch: "main"
        )
        var first = session(.codex, "one", title: "One", age: 2, workflow: .inProgress)
        var second = session(.claude, "two", title: "Two", age: 1, workflow: .inProgress)
        var ended = session(.codex, "ended", title: "Ended", age: 0, workflow: .completed)
        first.project = project
        second.project = project
        ended.project = project
        #expect(SessionQuery.conflictingWorktrees(in: [first, second, ended]) == [project.worktreeRoot])
    }

    @Test("Automatic archive skips pinned records and releases only old automatic emoji")
    func maintenanceRules() {
        let oldDate = now.addingTimeInterval(-3 * 86_400)
        var archive = session(.codex, "archive", title: "Archive", age: 3 * 86_400, workflow: .completed)
        archive.lifecycle = .completed(EndedSessionState(endedAt: oldDate))
        var pinned = archive
        pinned = session(.codex, "pinned", title: "Pinned", age: 3 * 86_400, workflow: .completed)
        pinned.lifecycle = .completed(EndedSessionState(endedAt: oldDate))
        pinned.isPinned = true
        var custom = session(.claude, "custom", title: "Custom", age: 4_000, workflow: .completed)
        custom.lifecycle = .completed(EndedSessionState(endedAt: now.addingTimeInterval(-4_000)))
        custom.emoji = .custom("😀")
        var collection = SessionCollection(sessions: [archive, pinned, custom])

        collection.applyAutomaticArchive(rules: OrganizationRules(autoArchiveAfterDays: 2), now: now)
        collection.releaseOldAutomaticEmojis(now: now)
        #expect(collection[archive.id]?.archivedAt == now)
        #expect(collection[pinned.id]?.archivedAt == nil)
        #expect(collection[archive.id]?.emoji == .historical)
        #expect(collection[custom.id]?.emoji == .custom("😀"))
    }

    private func session(
        _ provider: AgentProvider,
        _ externalID: String,
        title: String,
        age: TimeInterval,
        workflow: WorkflowBucket
    ) -> Session {
        let updated = now.addingTimeInterval(-age)
        let lifecycle: SessionLifecycle = switch workflow {
        case .inProgress: .active(ActiveSessionState(status: .processing))
        case .backlog: .backlog(EndedSessionState(endedAt: updated), order: 0)
        case .completed: .completed(EndedSessionState(endedAt: updated))
        }
        return Session(
            id: SessionID(provider: provider, externalID: externalID),
            sourceTitle: title,
            emoji: .automatic("🦉"),
            cwd: "/tmp/project",
            createdAt: updated.addingTimeInterval(-10),
            updatedAt: updated,
            lifecycle: lifecycle
        )
    }
}
