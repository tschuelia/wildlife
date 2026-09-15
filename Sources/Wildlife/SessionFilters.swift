import SwiftUI
import WildlifeDomain

struct SessionFilterMenu: View {
    @Bindable var library: SessionLibrary
    @State private var showingSave = false
    @State private var viewName = ""

    var body: some View {
        Menu {
            Section("Provider") {
                ForEach(AgentProvider.allCases) { provider in
                    Toggle(provider.displayName, isOn: membership(provider, keyPath: \.providers))
                }
            }
            Section("Workflow") {
                ForEach(WorkflowBucket.allCases) { workflow in
                    Toggle(workflow.displayName, isOn: membership(workflow, keyPath: \.workflows))
                }
            }
            Section("Focus") {
                Toggle("Favorites only", isOn: flag(\.pinnedOnly))
                Toggle("Attention only", isOn: flag(\.attentionOnly))
                Toggle("Include archived", isOn: flag(\.includeArchived))
                Picker("Updated", selection: recentDays) {
                    Text("Any time").tag(0)
                    Text("Today").tag(1)
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                }
            }
            if !library.queryResult.tags.isEmpty {
                Menu("Tags") {
                    ForEach(library.queryResult.tags, id: \.self) { tag in
                        Toggle(tag, isOn: membership(tag, keyPath: \.tags))
                    }
                }
            }
            if !library.queryResult.projects.isEmpty {
                Menu("Projects") {
                    ForEach(library.queryResult.projects, id: \.key) { project in
                        Toggle(project.name, isOn: membership(project.key, keyPath: \.projectKeys))
                    }
                }
            }
            Divider()
            Button("Save Current View…", systemImage: "bookmark.badge.plus") {
                viewName = ""
                showingSave = true
            }
            Button("Clear Filters") {
                library.applyView(SessionBuiltInView.all.id)
            }
        } label: {
            Label("Filters", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .alert("Save Current View", isPresented: $showingSave) {
            TextField("View name", text: $viewName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await library.saveView(name: viewName) } }
                .disabled(viewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var hasFilters: Bool {
        library.activeFilter != .builtIn(.all) || !library.searchText.isEmpty
    }

    private var recentDays: Binding<Int> {
        Binding(
            get: { library.activeFilter.recentDays ?? 0 },
            set: { value in update { $0.recentDays = value == 0 ? nil : value } }
        )
    }

    private func flag(_ keyPath: WritableKeyPath<SessionFilter, Bool>) -> Binding<Bool> {
        Binding(
            get: { library.activeFilter[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func membership<Value: Hashable>(
        _ value: Value,
        keyPath: WritableKeyPath<SessionFilter, Set<Value>>
    ) -> Binding<Bool> {
        Binding(
            get: { library.activeFilter[keyPath: keyPath].contains(value) },
            set: { enabled in
                update { filter in
                    if enabled { filter[keyPath: keyPath].insert(value) }
                    else { filter[keyPath: keyPath].remove(value) }
                }
            }
        )
    }

    private func update(_ mutation: (inout SessionFilter) -> Void) {
        mutation(&library.activeFilter)
        library.markFilterAsCustom()
    }
}
