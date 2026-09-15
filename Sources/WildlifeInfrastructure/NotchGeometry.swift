import CoreGraphics
import Foundation

/// Screen-space geometry for a Mac display with a camera housing in its top safe area.
///
/// The auxiliary top areas are the authoritative source for the horizontal edges of
/// the physical notch. A non-zero safe-area inset alone is not enough: maximized
/// windows and menu bars can also affect safe areas on displays without a notch.
package struct NotchGeometry: Equatable, Sendable {
    package let screenFrame: CGRect
    package let notchFrame: CGRect
    package let compactFrame: CGRect

    package var notchSize: CGSize { notchFrame.size }
    package var leftWingWidth: CGFloat { notchFrame.minX - compactFrame.minX }
    package var rightWingWidth: CGFloat { compactFrame.maxX - notchFrame.maxX }

    package init?(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        compactWingWidth: CGFloat = 30
    ) {
        guard safeAreaTop > 0,
              compactWingWidth >= 0,
              let leftArea = auxiliaryTopLeftArea,
              let rightArea = auxiliaryTopRightArea else {
            return nil
        }

        let notchMinX = max(screenFrame.minX, leftArea.maxX)
        let notchMaxX = min(screenFrame.maxX, rightArea.minX)
        guard notchMaxX > notchMinX else { return nil }

        let notch = CGRect(
            x: notchMinX,
            y: screenFrame.maxY - safeAreaTop,
            width: notchMaxX - notchMinX,
            height: safeAreaTop
        )
        let compactMinX = max(screenFrame.minX, notch.minX - compactWingWidth)
        let compactMaxX = min(screenFrame.maxX, notch.maxX + compactWingWidth)

        self.screenFrame = screenFrame
        self.notchFrame = notch
        self.compactFrame = CGRect(
            x: compactMinX,
            y: notch.minY,
            width: compactMaxX - compactMinX,
            height: notch.height
        )
    }

    /// Keeps the expanded island attached to the top edge and centered on the
    /// physical notch, while constraining it to the display.
    package func expandedFrame(width requestedWidth: CGFloat, height requestedHeight: CGFloat) -> CGRect {
        let width = min(screenFrame.width, max(requestedWidth, compactFrame.width))
        let height = min(screenFrame.height, max(requestedHeight, notchFrame.height))
        let idealX = notchFrame.midX - width / 2
        let x = min(max(idealX, screenFrame.minX), screenFrame.maxX - width)
        return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
    }

    package func panelFrame(
        expanded: Bool,
        expandedWidth: CGFloat,
        expandedHeight: CGFloat
    ) -> CGRect {
        expanded
            ? expandedFrame(width: expandedWidth, height: expandedHeight)
            : compactFrame
    }
}
