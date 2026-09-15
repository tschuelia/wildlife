import SwiftUI
import WildlifeDomain

struct SessionActionMenu: View {
    let session: Session
    let library: SessionLibrary
    let coordinator: AppCoordinator?
    let actions: SessionActionController
    let requestDeletion: () -> Void

    var body: some View {
        Menu {
            SessionActionItems(
                session: session,
                library: library,
                coordinator: coordinator,
                actions: actions,
                requestDeletion: requestDeletion
            )
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Session actions")
    }
}

struct SessionActionItems: View {
    let session: Session
    let library: SessionLibrary
    let coordinator: AppCoordinator?
    let actions: SessionActionController
    let requestDeletion: () -> Void

    var body: some View {
        Group {
            if session.workflow == .inProgress {
                Button("Focus Terminal", systemImage: "scope") { _ = actions.focus(session) }
                Button("Terminate Session…", systemImage: "stop.circle", role: .destructive) {
                    actions.requestTermination(session)
                }
                .disabled(actions.terminatingSessionIDs.contains(session.id))
            } else {
                Button("Resume Session…", systemImage: "play.circle") { actions.requestResume(session) }
            }
            Divider()
            Button("Reveal Project in Finder", systemImage: "folder") { actions.revealProject(session) }
            Button("Open Project in Terminal", systemImage: "terminal") { actions.openProjectInTerminal(session) }
            Button("Copy Project Path", systemImage: "doc.on.doc") { actions.copyProjectPath(session) }
            Button("Copy Session ID", systemImage: "key") { actions.copySessionID(session) }
            Button("Copy Resume Command", systemImage: "terminal.fill") { actions.copyResumeCommand(session) }
            Divider()
            Button(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin") {
                Task { await library.togglePinned(session.id) }
            }
            if session.workflow != .inProgress {
                Button(session.archivedAt == nil ? "Archive" : "Restore", systemImage: "archivebox") {
                    Task { await library.setArchived(session.archivedAt == nil, sessionID: session.id) }
                }
            }
            if session.attentionReason() != nil, let coordinator {
                Menu("Snooze Attention", systemImage: "clock") {
                    Button("15 Minutes") { Task { await coordinator.snooze(session, until: Date().addingTimeInterval(900)) } }
                    Button("1 Hour") { Task { await coordinator.snooze(session, until: Date().addingTimeInterval(3_600)) } }
                    Button("Until Tomorrow") { Task { await coordinator.snooze(session, until: tomorrowMorning) } }
                }
            }
            if session.workflow == .completed {
                Button("Move to Backlog", systemImage: "tray") { Task { await library.move(session.id, to: .backlog) } }
            } else if session.workflow == .backlog {
                Button("Mark Completed", systemImage: "checkmark.circle") { Task { await library.move(session.id, to: .completed) } }
            }
            Divider()
            Button("Remove from Wildlife", systemImage: "trash", role: .destructive, action: requestDeletion)
        }
    }

    private var tomorrowMorning: Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
