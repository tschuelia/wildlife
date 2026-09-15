import AppKit
import Combine
import CoreGraphics
import SwiftUI
import WildlifeCore

@MainActor
final class NotchPanelController {
    private static let compactWingWidth: CGFloat = 30
    private static let expandedWidth: CGFloat = 310

    private let repository: SessionRepository
    private let openManagerAction: () -> Void
    private let presentation = IslandPresentation()
    private let terminalSessionFocus = TerminalSessionFocus()
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    init(repository: SessionRepository, openManager: @escaping () -> Void) {
        self.repository = repository
        self.openManagerAction = openManager
        repository.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshVisibility() }
            }
            .store(in: &cancellables)
        presentation.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshVisibility() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)
        refreshVisibility()
    }

    private func refreshVisibility() {
        guard !repository.activeSessions.isEmpty,
              let screen = notchedBuiltInScreen(),
              geometry(for: screen) != nil else {
            presentation.collapse()
            panel?.orderOut(nil)
            return
        }
        if panel == nil { panel = makePanel() }
        layoutPanel(on: screen)
        panel?.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        let hostingView = NotchHostingView(rootView: NotchIslandView(
            repository: repository,
            presentation: presentation,
            focusSession: { [weak self] session in self?.focusSession(session) ?? false },
            openManager: { [weak self] in self?.openManagerAction() }
        ))
        hostingView.configure(presentation: presentation)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }

    private func focusSession(_ session: SessionRecord) -> Bool {
        let result = terminalSessionFocus.focus(session)
        if !result.succeeded {
            NSSound.beep()
        }
        return result.succeeded
    }

    private func layoutPanel(on screen: NSScreen) {
        guard let panel,
              let geometry = geometry(for: screen) else { return }
        let count = min(repository.activeSessions.count, 8)
        let expandedHeight = geometry.notchSize.height
            + CGFloat(58 + count * 43 + (repository.activeSessions.count > 8 ? 24 : 0))
        let expandedFrame = geometry.expandedFrame(width: Self.expandedWidth, height: expandedHeight)
        presentation.updateGeometry(geometry, expandedFrame: expandedFrame)
        let frame = geometry.panelFrame(
            expanded: presentation.expanded,
            expandedWidth: Self.expandedWidth,
            expandedHeight: expandedHeight
        )
        panel.setFrame(frame, display: true, animate: false)
    }

    private func notchedBuiltInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard geometry(for: screen) != nil,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    private func geometry(for screen: NSScreen) -> NotchGeometry? {
        NotchGeometry(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            compactWingWidth: Self.compactWingWidth
        )
    }
}

private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    private weak var presentation: IslandPresentation?
    private var islandTrackingArea: NSTrackingArea?
    private var presentationCancellable: AnyCancellable?

    func configure(presentation: IslandPresentation) {
        self.presentation = presentation
        presentationCancellable = presentation.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateTrackingAreas() }
            }
    }

    override func updateTrackingAreas() {
        if let islandTrackingArea {
            removeTrackingArea(islandTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: visibleIslandFrame,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        islandTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        presentation?.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        presentation?.pointerExited()
    }

    private var visibleIslandFrame: CGRect {
        guard let presentation else { return bounds }
        let size = CGSize(
            width: min(presentation.islandSize.width, bounds.width),
            height: min(presentation.islandSize.height, bounds.height)
        )
        let maximumX = max(bounds.minX, bounds.maxX - size.width)
        let x = min(max(bounds.minX + presentation.islandOriginX, bounds.minX), maximumX)
        return CGRect(x: x, y: bounds.maxY - size.height, width: size.width, height: size.height)
    }
}
