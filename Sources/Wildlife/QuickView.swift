import AppKit
import Observation
import SwiftUI
import WildlifeDomain
import WildlifeInfrastructure

struct QuickView: View {
    let library: SessionLibrary
    let actions: SessionActionController
    let openManager: (SessionID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Wildlife", systemImage: "pawprint.fill").font(.headline)
                Spacer()
                Text("\(library.activeSessions.count) active")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if library.activeSessions.isEmpty {
                ContentUnavailableView(
                    "No active sessions",
                    systemImage: "leaf",
                    description: Text("Start Codex or Claude in any terminal.")
                )
                .frame(height: 120)
            } else {
                ForEach(library.activeSessions.prefix(8)) { session in
                    HStack(spacing: 9) {
                        Text(session.emoji.value).font(.title2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.displayTitle).font(.callout.bold()).lineLimit(1)
                            Text(session.activeStatus?.displayName ?? "Ended")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusIndicator(status: session.activeStatus)
                        Button { _ = actions.focus(session) } label: { Image(systemName: "scope") }
                            .buttonStyle(.borderless)
                            .help("Focus terminal session")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openManager(session.id) }
                }
            }
            Divider()
            HStack {
                Button("Open Wildlife") { openManager(nil) }
                Spacer()
                Button("Quit Wildlife") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(13)
        .frame(width: 330)
    }
}

@MainActor
@Observable
final class IslandPresentation {
    private(set) var expanded = false
    private(set) var notchSize = CGSize(width: 185, height: 32)
    private(set) var compactSize = CGSize(width: 245, height: 32)
    private(set) var expandedSize = CGSize(width: 310, height: 32)
    private(set) var compactLeftWingWidth: CGFloat = 30
    private(set) var compactRightWingWidth: CGFloat = 30
    private(set) var expandedLeftWingWidth: CGFloat = 62.5
    private(set) var expandedRightWingWidth: CGFloat = 62.5
    private var collapseTask: Task<Void, Never>?

    var islandSize: CGSize { expanded ? expandedSize : compactSize }
    var leftWingWidth: CGFloat { expanded ? expandedLeftWingWidth : compactLeftWingWidth }
    var rightWingWidth: CGFloat { expanded ? expandedRightWingWidth : compactRightWingWidth }

    func updateGeometry(_ geometry: NotchGeometry, expandedFrame: CGRect) {
        notchSize = geometry.notchSize
        compactSize = geometry.compactFrame.size
        expandedSize = expandedFrame.size
        compactLeftWingWidth = geometry.leftWingWidth
        compactRightWingWidth = geometry.rightWingWidth
        expandedLeftWingWidth = geometry.notchFrame.minX - expandedFrame.minX
        expandedRightWingWidth = expandedFrame.maxX - geometry.notchFrame.maxX
    }

    func pointerEntered() {
        collapseTask?.cancel()
        expanded = true
    }

    func pointerExited() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            self?.expanded = false
        }
    }

    func toggle() {
        collapseTask?.cancel()
        expanded.toggle()
    }

    func collapse() {
        collapseTask?.cancel()
        expanded = false
    }
}

struct NotchIslandView: View {
    let library: SessionLibrary
    let presentation: IslandPresentation
    let focusSession: (Session) -> Bool
    let openManager: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            notchBar
            if presentation.expanded {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Wildlife", systemImage: "pawprint.fill").font(.headline)
                        Spacer()
                        Button("Open", systemImage: "rectangle.3.group") {
                            presentation.collapse()
                            openManager()
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(library.activeSessions.prefix(8)) { session in
                        Button {
                            if focusSession(session) { presentation.collapse() }
                        } label: {
                            HStack {
                                Text(session.emoji.value).font(.title3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.displayTitle).font(.callout.bold()).lineLimit(1)
                                    Text(session.activeStatus?.displayName ?? "Ended").font(.caption).foregroundStyle(.gray)
                                }
                                Spacer()
                                StatusIndicator(status: session.activeStatus)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if library.activeSessions.isEmpty {
                        Label("No active sessions", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    if library.activeSessions.count > 8 {
                        Text("\(library.activeSessions.count - 8) more in Wildlife").font(.caption).foregroundStyle(.gray)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: presentation.islandSize.width, height: presentation.islandSize.height, alignment: .top)
        .foregroundStyle(.white)
        .background(Color.black, in: AttachedNotchShape())
        .clipShape(AttachedNotchShape())
        .animation(.snappy(duration: 0.22), value: presentation.expanded)
    }

    private var notchBar: some View {
        HStack(spacing: 0) {
            Group {
                if let session = library.activeSessions.first { Text(session.emoji.value).font(.system(size: 18)) }
                else { Image(systemName: "pawprint.fill").font(.system(size: 15, weight: .semibold)) }
            }
            .padding(.trailing, 7)
            .frame(width: presentation.leftWingWidth, alignment: .trailing)
            Color.clear.frame(width: presentation.notchSize.width)
            Group {
                if library.activeSessions.count > 1 {
                    Text(library.activeSessions.count > 9 ? "9+" : "\(library.activeSessions.count)")
                        .font(.caption2.bold())
                } else {
                    StatusIndicator(status: library.activeSessions.first?.activeStatus)
                }
            }
            .padding(.leading, 7)
            .frame(width: presentation.rightWingWidth, alignment: .leading)
        }
        .frame(height: presentation.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture { presentation.toggle() }
    }
}

private struct AttachedNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 14, style: .continuous).path(in: rect)
    }
}

struct StatusIndicator: View {
    let status: ActiveStatus?

    var body: some View {
        Circle()
            .fill(status?.color ?? .secondary)
            .frame(width: 8, height: 8)
            .shadow(color: (status?.color ?? .clear).opacity(0.6), radius: (status?.priority ?? 3) <= 1 ? 4 : 0)
            .accessibilityLabel(status?.displayName ?? "Ended")
    }
}

extension ActiveStatus {
    var color: Color {
        switch self {
        case .waitingForApproval, .error: .orange
        case .processing, .runningTool, .compacting, .starting: .green
        case .waitingForInput: .blue
        }
    }
}
