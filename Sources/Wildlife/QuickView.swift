import SwiftUI
import WildlifeCore

struct QuickView: View {
    @ObservedObject var repository: SessionRepository
    @ObservedObject var settings: AppSettings
    let openManager: (String?) -> Void
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Wildlife", systemImage: "pawprint.fill").font(.headline)
                Spacer()
                Text("\(repository.activeSessions.count) active")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if repository.activeSessions.isEmpty {
                ContentUnavailableView(
                    "No active sessions",
                    systemImage: "leaf",
                    description: Text("Start Codex or Claude in any terminal.")
                )
                .frame(height: 120)
            } else {
                ForEach(repository.activeSessions, id: \.stableKey) { session in
                    HStack(spacing: 9) {
                        Text(session.emoji).font(.title2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.displayTitle).font(.callout.bold()).lineLimit(1)
                            Text(session.runtimeStatus.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusDot(status: session.runtimeStatus)
                        Button {
                            do {
                                try repository.copyResumeCommand(session, settings: settings)
                                message = "Command copied"
                            } catch {
                                message = error.localizedDescription
                            }
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy resume command")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openManager(session.stableKey) }
                }
            }
            Divider()
            HStack {
                Button("Open Wildlife") { openManager(nil) }
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(13)
        .frame(width: 330)
    }
}

@MainActor
final class IslandPresentation: ObservableObject {
    static let collapseDelay: Duration = .milliseconds(200)

    @Published private(set) var expanded = false
    @Published private(set) var notchSize = CGSize(width: 185, height: 32)
    @Published private(set) var compactSize = CGSize(width: 245, height: 32)
    @Published private(set) var expandedSize = CGSize(width: 310, height: 32)
    @Published private(set) var compactLeftWingWidth: CGFloat = 30
    @Published private(set) var compactRightWingWidth: CGFloat = 30
    @Published private(set) var expandedLeftWingWidth: CGFloat = 62.5
    @Published private(set) var expandedRightWingWidth: CGFloat = 62.5

    private var collapseTask: Task<Void, Never>?

    var islandSize: CGSize { expanded ? expandedSize : compactSize }
    var islandOriginX: CGFloat { 0 }
    var leftWingWidth: CGFloat { expanded ? expandedLeftWingWidth : compactLeftWingWidth }
    var rightWingWidth: CGFloat { expanded ? expandedRightWingWidth : compactRightWingWidth }

    func updateGeometry(_ geometry: NotchGeometry, expandedFrame: CGRect) {
        if notchSize != geometry.notchSize { notchSize = geometry.notchSize }
        if compactSize != geometry.compactFrame.size { compactSize = geometry.compactFrame.size }
        if expandedSize != expandedFrame.size { expandedSize = expandedFrame.size }
        if compactLeftWingWidth != geometry.leftWingWidth { compactLeftWingWidth = geometry.leftWingWidth }
        if compactRightWingWidth != geometry.rightWingWidth { compactRightWingWidth = geometry.rightWingWidth }

        let newExpandedLeftWingWidth = geometry.notchFrame.minX - expandedFrame.minX
        let newExpandedRightWingWidth = expandedFrame.maxX - geometry.notchFrame.maxX
        if expandedLeftWingWidth != newExpandedLeftWingWidth {
            expandedLeftWingWidth = newExpandedLeftWingWidth
        }
        if expandedRightWingWidth != newExpandedRightWingWidth {
            expandedRightWingWidth = newExpandedRightWingWidth
        }
    }

    func pointerEntered() {
        cancelPendingCollapse()
        setExpanded(true)
    }

    func pointerExited() {
        cancelPendingCollapse()
        guard expanded else { return }
        collapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.collapseDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.collapseTask = nil
            self?.setExpanded(false)
        }
    }

    func toggleExpansion() {
        cancelPendingCollapse()
        setExpanded(!expanded)
    }

    func collapse() {
        cancelPendingCollapse()
        setExpanded(false)
    }

    private func cancelPendingCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func setExpanded(_ expanded: Bool) {
        guard self.expanded != expanded else { return }
        self.expanded = expanded
    }
}

struct NotchIslandView: View {
    @ObservedObject var repository: SessionRepository
    @ObservedObject var presentation: IslandPresentation
    let focusSession: (SessionRecord) -> Bool
    let openManager: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            islandContent
                .frame(
                    width: presentation.islandSize.width,
                    height: presentation.islandSize.height,
                    alignment: .top
                )
                .foregroundStyle(.white)
                .background(Color.black, in: AttachedNotchShape())
                .clipShape(AttachedNotchShape())
                .contentShape(AttachedNotchShape())
                .offset(x: presentation.islandOriginX)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.22), value: presentation.expanded)
    }

    private var islandContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            notchBar
            if presentation.expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Wildlife", systemImage: "pawprint.fill").font(.headline)
                        Spacer()
                        Button {
                            presentation.collapse()
                            openManager()
                        } label: {
                            Label("Open Wildlife", systemImage: "rectangle.3.group")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Open the Wildlife lane view")
                        Button {
                            presentation.collapse()
                        } label: {
                            Image(systemName: "chevron.up").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Collapse")
                    }
                    ForEach(repository.activeSessions.prefix(8), id: \.stableKey) { session in
                        Button {
                            if focusSession(session) {
                                presentation.collapse()
                            }
                        } label: {
                            HStack {
                                Text(session.emoji).font(.title3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.displayTitle).font(.callout.bold()).lineLimit(1)
                                    Text(session.runtimeStatus.displayName).font(.caption).foregroundStyle(.gray)
                                }
                                Spacer()
                                Circle().fill(session.runtimeStatus.attentionColor).frame(width: 8, height: 8)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if repository.activeSessions.count > 8 {
                        Text("\(repository.activeSessions.count - 8) more in Wildlife")
                            .font(.caption).foregroundStyle(.gray)
                    }
                }
                .padding(.top, 10)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var notchBar: some View {
        HStack(spacing: 0) {
            Group {
                if let session = repository.activeSessions.first {
                    Text(session.emoji)
                        .font(.system(size: 18))
                        .accessibilityLabel(session.displayTitle)
                }
            }
            .padding(.trailing, 7)
            .frame(
                minWidth: presentation.leftWingWidth,
                maxWidth: presentation.leftWingWidth,
                maxHeight: .infinity,
                alignment: .trailing
            )

            Color.clear
                .frame(width: presentation.notchSize.width)
                .accessibilityHidden(true)

            Group {
                if let session = repository.activeSessions.first, repository.activeSessions.count > 1 {
                    ZStack {
                        Circle()
                            .fill(session.runtimeStatus.attentionColor)
                            .frame(width: 18, height: 18)
                        Text(repository.activeSessions.count > 9 ? "9+" : "\(repository.activeSessions.count)")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black.opacity(0.75))
                    }
                    .shadow(color: session.runtimeStatus.attentionColor.opacity(0.55), radius: 3)
                } else if let session = repository.activeSessions.first {
                    StatusDot(status: session.runtimeStatus)
                }
            }
            .padding(.leading, 7)
            .frame(
                minWidth: presentation.rightWingWidth,
                maxWidth: presentation.rightWingWidth,
                maxHeight: .infinity,
                alignment: .leading
            )
        }
        .frame(height: presentation.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture { presentation.toggleExpansion() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactAccessibilityLabel)
    }

    private var compactAccessibilityLabel: String {
        guard let session = repository.activeSessions.first else { return "No active sessions" }
        let additional = repository.activeSessions.count - 1
        return additional > 0
            ? "\(session.displayTitle), \(session.runtimeStatus.displayName), and \(additional) more sessions"
            : "\(session.displayTitle), \(session.runtimeStatus.displayName)"
    }
}

private struct AttachedNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topRadius = min(6, rect.height / 2, rect.width / 2)
        let bottomRadius = min(14, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
