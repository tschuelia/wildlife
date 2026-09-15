import SwiftUI
import WildlifeDomain

struct SessionCommands: Commands {
    let application: ApplicationModel

    var body: some Commands {
        CommandMenu("Sessions") {
            if let library = application.library, let coordinator = application.coordinator {
                ForEach(Array(SessionBuiltInView.allCases.enumerated()), id: \.element.id) { index, view in
                    Button(view.displayName) { library.applyView(view.id) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
                Button("Previous Session") { library.selectAdjacent(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Session") { library.selectAdjacent(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Focus or Resume Selected") {
                    guard let session = library.selectedSession else { return }
                    if session.workflow == .inProgress { _ = coordinator.actions.focus(session) }
                    else { coordinator.actions.requestResume(session) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(library.selectedSession == nil)
                Button(library.selectedSession?.isPinned == true ? "Unpin Selected" : "Pin Selected") {
                    guard let id = library.selectedSessionID else { return }
                    Task { await library.togglePinned(id) }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(library.selectedSession == nil)
                Button(library.selectedSession?.archivedAt == nil ? "Archive Selected" : "Restore Selected") {
                    guard let session = library.selectedSession else { return }
                    Task { await library.setArchived(session.archivedAt == nil, sessionID: session.id) }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(library.selectedSession?.workflow == .inProgress || library.selectedSession == nil)
            }
        }
    }
}
