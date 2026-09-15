import AppKit
import CoreGraphics
import Observation
import SwiftUI
import WildlifeDomain
import WildlifeInfrastructure

@MainActor
final class NotchPanelController {
    private static let compactWingWidth: CGFloat = 30
    private static let expandedWidth: CGFloat = 310

    private let library: SessionLibrary
    private let focusSessionAction: (Session) -> Bool
    private let openManagerAction: () -> Void
    private let presentation = IslandPresentation()
    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var isShutdown = false

    init(
        library: SessionLibrary,
        focusSession: @escaping (Session) -> Bool,
        openManager: @escaping () -> Void
    ) {
        self.library = library
        self.focusSessionAction = focusSession
        self.openManagerAction = openManager
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshVisibility() } }
        observeState()
        refreshVisibility()
    }

    func shutdown() {
        isShutdown = true
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        presentation.collapse()
        panel?.orderOut(nil)
        panel = nil
    }

    private func refreshVisibility() {
        guard !isShutdown else { return }
        guard let screen = notchedBuiltInScreen(),
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
            library: library,
            presentation: presentation,
            focusSession: { [weak self] session in self?.focusSessionAction(session) ?? false },
            openManager: { [weak self] in self?.openManagerAction() }
        ))
        hostingView.configure(presentation: presentation)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }

    private func layoutPanel(on screen: NSScreen) {
        guard let panel,
              let geometry = geometry(for: screen) else { return }
        let count = min(library.activeSessions.count, 8)
        let visibleRowCount = max(count, 1)
        let expandedHeight = geometry.notchSize.height
            + CGFloat(58 + visibleRowCount * 43 + (library.activeSessions.count > 8 ? 24 : 0))
        let expandedFrame = geometry.expandedFrame(width: Self.expandedWidth, height: expandedHeight)
        presentation.updateGeometry(geometry, expandedFrame: expandedFrame)
        let frame = geometry.panelFrame(
            expanded: presentation.expanded,
            expandedWidth: Self.expandedWidth,
            expandedHeight: expandedHeight
        )
        panel.setFrame(frame, display: true, animate: false)
    }

    private func observeState() {
        withObservationTracking {
            _ = library.activeSessions.count
            _ = presentation.expanded
        } onChange: { [weak self] in
            Task { @MainActor in
                guard self?.isShutdown == false else { return }
                self?.refreshVisibility()
                self?.observeState()
            }
        }
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

    func configure(presentation: IslandPresentation) {
        self.presentation = presentation
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
        return CGRect(x: bounds.minX, y: bounds.maxY - size.height, width: size.width, height: size.height)
    }
}
