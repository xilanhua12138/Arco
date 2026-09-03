import AppKit
import CoreGraphics

/// Native point sizes copied from the established window contract.
enum ArcoWindowMetrics {
    static let mainSize = CGSize(width: 1_240, height: 820)
    static let mainMinimumSize = CGSize(width: 980, height: 680)

    static let hudSize = CGSize(width: 368, height: 56)
    static let meetingPromptSize = CGSize(width: 372, height: 140)
    static let agentSize = CGSize(width: 720, height: 560)
    static let collapsedAgentSize = CGSize(width: 432, height: 560)
    static let agentMaximumSize = CGSize(width: 820, height: 720)

    static let hudBottomMargin: CGFloat = 24
    static let agentTopMargin: CGFloat = 20
    static let agentRightMargin: CGFloat = 20
    static let agentHUDGap: CGFloat = 20
    static let meetingPromptTopMargin: CGFloat = 18
    static let meetingPromptRightMargin: CGFloat = 18
}

/// Point-space geometry used by tao/wry for the source
/// `trafficLightPosition: { x: 27, y: 26 }` contract.
///
/// `x` is the close button's left edge in its `NSTitlebarView`. `y` is not a
/// direct button origin: tao adds it to the close-button height and uses that
/// sum as the `NSTitlebarContainerView` height. The close button's existing
/// vertical origin is intentionally preserved.
enum ArcoWindowChromeGeometry {
    static let sourceTrafficLightPosition = CGPoint(x: 27, y: 26)

    static func titlebarContainerFrame(
        current: CGRect,
        windowHeight: CGFloat,
        closeButtonFrame: CGRect
    ) -> CGRect {
        var frame = current
        frame.size.height = closeButtonFrame.height + sourceTrafficLightPosition.y
        frame.origin.y = windowHeight - frame.height
        return frame
    }

    static func trafficLightOrigin(
        current: CGPoint,
        index: Int,
        spacing: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: sourceTrafficLightPosition.x + CGFloat(index) * spacing,
            y: current.y
        )
    }
}

/// A small value type keeps the placement math independent from `NSScreen`, so
/// moving among Retina/non-Retina displays cannot accidentally mix pixels and
/// points. `visibleFrame` is already expressed in native AppKit points.
struct ScreenWorkArea: Equatable {
    var frame: CGRect

    init(_ screen: NSScreen) {
        frame = screen.visibleFrame
    }

    init(frame: CGRect) {
        self.frame = frame
    }
}

enum ArcoWindowPlacement {
    static func hudFrame(in area: ScreenWorkArea) -> CGRect {
        let size = ArcoWindowMetrics.hudSize
        return CGRect(
            x: area.frame.minX + max(0, (area.frame.width - size.width) / 2),
            y: area.frame.minY + min(
                ArcoWindowMetrics.hudBottomMargin,
                area.frame.height - size.height
            ),
            width: size.width,
            height: size.height
        )
    }

    static func fittedAgentSize(
        in area: ScreenWorkArea,
        requested: CGSize
    ) -> CGSize {
        // This is the point-space equivalent of overlay.rs. The reserved
        // bottom band keeps the bottom-centred HUD and its 20 pt quiet gap
        // unobscured, even on a very small display.
        let availableWidth = max(
            1,
            area.frame.width - ArcoWindowMetrics.agentRightMargin * 2
        )
        let availableHeight = max(
            1,
            area.frame.height
                - ArcoWindowMetrics.agentTopMargin
                - ArcoWindowMetrics.hudSize.height
                - ArcoWindowMetrics.hudBottomMargin
                - ArcoWindowMetrics.agentHUDGap
        )
        return CGSize(
            width: min(requested.width, availableWidth),
            height: min(requested.height, availableHeight)
        )
    }

    static func meetingPromptFrame(in area: ScreenWorkArea) -> CGRect {
        let size = ArcoWindowMetrics.meetingPromptSize
        return CGRect(
            x: max(
                area.frame.minX,
                area.frame.maxX - size.width - ArcoWindowMetrics.meetingPromptRightMargin
            ),
            y: max(
                area.frame.minY,
                area.frame.maxY - size.height - ArcoWindowMetrics.meetingPromptTopMargin
            ),
            width: min(size.width, area.frame.width),
            height: min(size.height, area.frame.height)
        )
    }

    static func agentFrame(
        in area: ScreenWorkArea,
        requested: CGSize
    ) -> CGRect {
        let size = fittedAgentSize(in: area, requested: requested)
        return CGRect(
            x: max(
                area.frame.minX,
                area.frame.maxX - size.width - ArcoWindowMetrics.agentRightMargin
            ),
            y: area.frame.maxY - size.height - ArcoWindowMetrics.agentTopMargin,
            width: size.width,
            height: size.height
        )
    }

    /// AppKit frames are anchored at the lower-left. The previous placement
    /// preserved the upper-left outer position while changing size, so adjust
    /// `origin.y` explicitly to retain that same visual anchor.
    static func resizingPreservingTopLeft(
        _ frame: CGRect,
        to size: CGSize
    ) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
