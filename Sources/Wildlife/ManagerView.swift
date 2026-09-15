import AppKit
import SwiftUI
import WildlifeDomain
import WildlifeInfrastructure

struct ManagerView: View {
    @Bindable var library: SessionLibrary
    @Bindable var preferences: PreferencesStore
    @Bindable var integrations: IntegrationManager
    @Bindable var coordinator: AppCoordinator
    @Bindable var actions: SessionActionController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showingOnboarding = false

    var body: some View {
        NavigationSplitView {
            SessionSidebar(library: library)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            SessionListView(
                library: library,
                preferences: preferences,
                coordinator: coordinator,
                actions: actions
            )
                .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        } detail: {
            if let session = library.selectedSession {
                SessionInspector(
                    session: session,
                    library: library,
                    coordinator: coordinator,
                    actions: actions
                )
                .id(session.id)
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "pawprint",
                    description: Text("Session activity, notes, and actions appear here.")
                )
            }
        }
        .navigationTitle("Wildlife")
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search sessions")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SessionFilterMenu(library: library)
                Button("Settings", systemImage: "gear") { openSettings() }
            }
        }
        .frame(minWidth: 1_050, minHeight: 650)
        .task {
            await coordinator.start { openWindow(id: "manager") }
            await integrations.refresh()
            showingOnboarding = !preferences.value.onboardingCompleted
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(preferences: preferences, integrations: integrations) {
                showingOnboarding = false
            }
        }
        .confirmationDialog(
            "Resume session in \(preferences.value.preferredTerminal.displayName)?",
            isPresented: resumeConfirmation,
            presenting: pendingResumeSession
        ) { session in
            Button("Run Resume Command") { actions.confirmResume(session.id) }
            Button("Cancel", role: .cancel) { actions.pendingResumeSessionID = nil }
        } message: { session in
            Text((try? actions.renderedResumeCommand(for: session)) ?? "The resume command is invalid.")
        }
        .confirmationDialog(
            "Terminate this session?",
            isPresented: terminationConfirmation,
            presenting: pendingTerminationSession
        ) { session in
            Button("Terminate Session", role: .destructive) { actions.confirmTermination(session.id) }
            Button("Cancel", role: .cancel) { actions.pendingTerminationSessionID = nil }
        } message: { _ in
            Text("Wildlife sends SIGTERM only after revalidating the process identity. Provider session data is not removed.")
        }
        .alert("Wildlife needs attention", isPresented: errorPresentation) {
            Button("Retry") { Task { await coordinator.retryStartup() } }
            Button("Reveal Data Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([RuntimePaths.applicationSupportDirectory])
            }
            Button("Dismiss", role: .cancel) { library.clearError(); coordinator.clearError() }
        } message: {
            Text(library.errorMessage ?? coordinator.runtimeError ?? "Unknown error")
        }
        .overlay(alignment: .bottom) {
            if let message = actions.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .task(id: message) {
                        do { try await Task.sleep(for: .seconds(3)) }
                        catch { return }
                        if actions.message == message { actions.message = nil }
                    }
            }
        }
    }

    private var pendingResumeSession: Session? {
        actions.pendingResumeSessionID.flatMap(library.session)
    }

    private var pendingTerminationSession: Session? {
        actions.pendingTerminationSessionID.flatMap(library.session)
    }

    private var resumeConfirmation: Binding<Bool> {
        Binding(
            get: { pendingResumeSession != nil },
            set: { if !$0 { actions.pendingResumeSessionID = nil } }
        )
    }

    private var terminationConfirmation: Binding<Bool> {
        Binding(
            get: { pendingTerminationSession != nil },
            set: { if !$0 { actions.pendingTerminationSessionID = nil } }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { library.errorMessage != nil || coordinator.runtimeError != nil },
            set: { if !$0 { library.clearError(); coordinator.clearError() } }
        )
    }
}

private struct SessionSidebar: View {
    @Bindable var library: SessionLibrary

    var body: some View {
        List(selection: $library.selectedViewID) {
            Section("Smart Views") {
                ForEach(SessionBuiltInView.allCases) { view in
                    Label(view.displayName, systemImage: icon(for: view)).tag(view.id)
                }
            }
            Section("Workflow") {
                ForEach(WorkflowBucket.allCases) { workflow in
                    Label(workflow.displayName, systemImage: icon(for: workflow))
                        .tag("workflow:\(workflow.rawValue)")
                }
            }
            if !library.savedViews.isEmpty {
                Section("Saved Views") {
                    ForEach(library.savedViews) { view in
                        Label(view.name, systemImage: "bookmark").tag(view.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: library.selectedViewID) { _, id in library.applyView(id) }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(library.queryResult.sessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if library.savedViews.contains(where: { $0.id == library.selectedViewID }) {
                    Button("Delete View", systemImage: "trash", role: .destructive) {
                        Task { await library.deleteSelectedView() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private func icon(for view: SessionBuiltInView) -> String {
        switch view {
        case .all: "square.stack.3d.up"
        case .attention: "bell.badge"
        case .favorites: "pin"
        case .recent: "clock"
        case .archived: "archivebox"
        }
    }

    private func icon(for workflow: WorkflowBucket) -> String {
        switch workflow {
        case .inProgress: "bolt.fill"
        case .backlog: "tray"
        case .completed: "checkmark.circle"
        }
    }
}
