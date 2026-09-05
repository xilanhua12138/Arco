import AppKit
import SwiftUI

/// The presentation layer's translation contract. Callers own the selected
/// locale; views only ask for the same keys used by the original application.
public typealias ArcoTranslate = (_ key: String, _ parameters: [String: String]) -> String

/// Literal SwiftUI counterparts of the original color tokens.
public enum ArcoNativeColors {
    public static let surfaceStageBase = Color.white
    public static let surfaceStage = Color.white
    public static let surfaceDocument = Color.white
    public static let surfaceSheetContent = Color.white.opacity(0.68)
    public static let surfaceRaised = Color.white
    public static let surfaceSubtle = Color(white: 246 / 255)
    public static let surfaceSidebar = Color(white: 246 / 255)
    public static let surfaceHover = Color(red: 119 / 255, green: 119 / 255, blue: 119 / 255).opacity(0.07)
    public static let surfaceSelected = Color(white: 232 / 255)
    public static let surfaceNavigation = Color(white: 246 / 255)
    public static let surfacePopover = Color.white.opacity(0.94)
    public static let surfaceControlFill = Color.white.opacity(0.24)
    public static let surfaceSettingsShell = Color.white
    public static let surfaceSettingsNavigation = Color(white: 246 / 255)
    public static let surfaceSettingsContent = Color.white

    public static let inkStrong = Color(white: 25 / 255)
    public static let ink = Color(white: 52 / 255)
    public static let inkMuted = Color(white: 102 / 255)
    public static let inkFaint = Color(white: 102 / 255)

    public static let line = Color(red: 119 / 255, green: 119 / 255, blue: 119 / 255).opacity(0.18)
    public static let lineThin = Color(red: 119 / 255, green: 119 / 255, blue: 119 / 255).opacity(0.07)
    public static let lineStrong = Color(red: 119 / 255, green: 119 / 255, blue: 119 / 255).opacity(0.30)

    public static let action = brand
    public static let actionHover = Color(red: 26 / 255, green: 74 / 255, blue: 209 / 255)
    public static let actionInk = Color.white
    public static let brand = Color(red: 36 / 255, green: 92 / 255, blue: 245 / 255)
    public static let brandSoft = Color(red: 52 / 255, green: 107 / 255, blue: 255 / 255).opacity(0.10)
    public static let record = Color(red: 198 / 255, green: 45 / 255, blue: 65 / 255)
    public static let recordSoft = Color(red: 252 / 255, green: 239 / 255, blue: 240 / 255)
    public static let success = Color(red: 0 / 255, green: 135 / 255, blue: 112 / 255)
    public static let warning = Color(red: 154 / 255, green: 91 / 255, blue: 0 / 255)
    public static let scrim = Color.black.opacity(0.50)
    public static let stageFrame = Color.clear
    public static let surfaceInnerHighlight = Color.white.opacity(0.94)
    public static let surfaceEdgeHighlight = Color.white.opacity(0.76)
}

/// One motion vocabulary for the whole product. Interactive springs start at
/// the presentation value, remain interruptible, and settle without bounce.
public enum ArcoMotion {
    public static let press = Animation.interactiveSpring(
        response: 0.11,
        dampingFraction: 1,
        blendDuration: 0
    )
    public static let hover = Animation.easeOut(duration: 0.16)
    public static let state = Animation.interactiveSpring(
        response: 0.22,
        dampingFraction: 1,
        blendDuration: 0
    )
    public static let sheet = Animation.interactiveSpring(
        response: 0.26,
        dampingFraction: 1,
        blendDuration: 0
    )
}

/// Immediate pointer-down feedback shared by custom plain buttons. Reduced
/// Motion retains a contrast response while removing the spatial scale.
public struct ArcoPressFeedbackButtonStyle: ButtonStyle {
    private let pressedScale: CGFloat
    private let pressedOpacity: Double

    public init(pressedScale: CGFloat = 0.97, pressedOpacity: Double = 0.86) {
        self.pressedScale = pressedScale
        self.pressedOpacity = pressedOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        ArcoPressFeedbackButton(
            configuration: configuration,
            pressedScale: pressedScale,
            pressedOpacity: pressedOpacity
        )
    }
}

private struct ArcoPressFeedbackButton: View {
    let configuration: ButtonStyleConfiguration
    let pressedScale: CGFloat
    let pressedOpacity: Double
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && isEnabled && !accessibilityReduceMotion
                    ? pressedScale
                    : 1
            )
            .opacity(configuration.isPressed && isEnabled ? pressedOpacity : 1)
            .animation(
                accessibilityReduceMotion ? .easeOut(duration: 0.08) : ArcoMotion.press,
                value: configuration.isPressed
            )
    }
}

public extension View {
    /// macOS 26 Liquid Glass with the same regular-material fallback used by
    /// Arco's former AppKit bridge on older systems.
    @ViewBuilder
    func arcoLiquidGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(ArcoLiquidGlassModifier(shape: shape, interactive: interactive))
    }
}

private struct ArcoLiquidGlassModifier<GlassShape: Shape>: ViewModifier {
    let shape: GlassShape
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if accessibilityReduceTransparency {
            content
                .background(ArcoNativeColors.surfaceRaised, in: shape)
                .overlay(
                    shape.stroke(
                        colorSchemeContrast == .increased
                            ? ArcoNativeColors.inkStrong.opacity(0.44)
                            : ArcoNativeColors.lineStrong,
                        lineWidth: colorSchemeContrast == .increased ? 1.25 : 0.75
                    )
                )
        } else if #available(macOS 26.0, *) {
            Group {
                if interactive {
                    content.glassEffect(.regular.interactive(), in: shape)
                } else {
                    content.glassEffect(.regular, in: shape)
                }
            }
            .overlay {
                if colorSchemeContrast == .increased {
                    shape.stroke(ArcoNativeColors.inkStrong.opacity(0.34), lineWidth: 1)
                }
            }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(
                    shape.stroke(
                        colorSchemeContrast == .increased
                            ? ArcoNativeColors.inkStrong.opacity(0.36)
                            : Color.white.opacity(0.28),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                )
        }
    }
}

struct ArcoSpinningRefreshIcon: View {
    let active: Bool
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        if accessibilityReduceMotion {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size))
                .opacity(active ? 0.72 : 1)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { timeline in
                let phase = active
                    ? timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 0.8) / 0.8
                    : 0
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: size))
                    .rotationEffect(.degrees(phase * 360))
            }
        }
    }
}

/// Point-for-point constants from App.css and native_shell.rs. Keeping these
/// values named makes the Swift layout auditable against the source UI rather
/// than deriving a new visual system during the port.
public enum ArcoLayoutMetrics {
    public struct WorkspaceColumnWidths: Equatable, Sendable {
        public var transcript: CGFloat
        public var agent: CGFloat
    }

    public static let windowInset: CGFloat = 8
    public static let sidebarWidth: CGFloat = 210
    public static let sidebarStageGap: CGFloat = 8
    public static let sidebarCornerRadius: CGFloat = 20
    public static let pageCornerRadius: CGFloat = 20
    public static let titlebarClearance: CGFloat = 32
    public static let sidebarTitlebarClearance: CGFloat = 44
    public static let pageBottomPadding: CGFloat = 16
    public static let workspacePadding: CGFloat = 10
    public static let workspaceGap: CGFloat = 20
    public static let workspaceCornerRadius: CGFloat = 16
    public static let compactViewportBreakpoint: CGFloat = 1_024
    public static let workspaceSplitMinimumWidth: CGFloat = 740
    public static let transcriptReadingMaximumWidth: CGFloat = 720
    public static let idleMediumViewportBreakpoint: CGFloat = 1_100
    public static let idleStackedViewportBreakpoint: CGFloat = 880

    public static func currentPageHorizontalPadding(viewportWidth: CGFloat) -> CGFloat {
        viewportWidth <= compactViewportBreakpoint ? 12 : 16
    }

    /// Cap the optional Agent at 400pt; at compact widths both readers retain
    /// equal space. Callers stack below workspaceSplitMinimumWidth.
    public static func workspaceColumnWidths(
        contentWidth: CGFloat,
        compactColumns: Bool
    ) -> WorkspaceColumnWidths {
        let available = max(0, contentWidth)
        let agent = min(400, available / 2)
        return WorkspaceColumnWidths(transcript: available - agent, agent: agent)
    }

    public static func historyPageHorizontalPadding(viewportWidth: CGFloat) -> CGFloat {
        viewportWidth <= compactViewportBreakpoint ? 20 : 24
    }

    public static func notesPageHorizontalPadding(viewportWidth: CGFloat) -> CGFloat {
        viewportWidth <= compactViewportBreakpoint ? 20 : 16
    }
}

/// Native counterpart of the source `data-tauri-drag-region` strips. It owns
/// no pixels: it only forwards the gesture to AppKit, while controls layered
/// outside the strip keep their normal hit targets.
public struct ArcoWindowDragRegion: View {
    public init() {}

    public var body: some View {
        if #available(macOS 15.0, *) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        } else {
            ArcoLegacyWindowDragRegion()
        }
    }
}

private struct ArcoLegacyWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragRegionView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragRegionView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// These values are copied from ArcoGlassControls.swift. They intentionally do
/// not reuse the CSS palette: the established native controls use Apple's glass
/// with these stronger native tints on macOS 26.
public enum ArcoNativeGlassPalette {
    public static let action = ArcoNativeColors.brand
    public static let recording = ArcoNativeColors.record
    public static let shellBase = ArcoNativeColors.surfaceSidebar
    public static let ink = ArcoNativeColors.inkStrong
    public static let secondaryInk = ArcoNativeColors.inkMuted
}

public enum ArcoGlassSurfaceTone: Sendable {
    case neutral
    case accent
    case elevated

    fileprivate var tint: Color? {
        switch self {
        case .neutral: nil
        case .accent: Color(red: 0.24, green: 0.55, blue: 0.95).opacity(0.10)
        case .elevated: Color.white.opacity(0.08)
        }
    }
}

/// Direct SwiftUI form of the source glass-surface contract. The material is
/// the content's actual background rather than a separately hosted layer.
public struct ArcoGlassSurface<Content: View>: View {
    private let cornerRadius: CGFloat
    private let tone: ArcoGlassSurfaceTone
    private let interactive: Bool
    private let content: Content
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(
        cornerRadius: CGFloat,
        tone: ArcoGlassSurfaceTone,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tone = tone
        self.interactive = interactive
        self.content = content()
    }

    public var body: some View {
        content.background { glass }
    }

    @ViewBuilder private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if accessibilityReduceTransparency {
            Color.clear
                .background(ArcoNativeColors.surfaceRaised, in: shape)
                .overlay(
                    shape.strokeBorder(
                        colorSchemeContrast == .increased
                            ? ArcoNativeColors.inkStrong.opacity(0.44)
                            : ArcoNativeColors.lineStrong,
                        lineWidth: colorSchemeContrast == .increased ? 1.25 : 0.75
                    )
                )
                .allowsHitTesting(false)
        } else if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                Color.clear
                    .glassEffect(
                        .regular.tint(tone.tint).interactive(interactive),
                        in: shape
                    )
            }
            .overlay {
                if colorSchemeContrast == .increased {
                    shape.strokeBorder(ArcoNativeColors.inkStrong.opacity(0.34), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        } else {
            Color.clear
                .background(.regularMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(
                        colorSchemeContrast == .increased
                            ? ArcoNativeColors.inkStrong.opacity(0.36)
                            : .white.opacity(0.26),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                    )
                )
                .allowsHitTesting(false)
        }
    }
}

public enum ArcoNativeActionVariant: Sendable {
    case prominent
    case standard
    case toolbar
}

/// Direct SwiftUI form of ArcoGlassActionRoot. Its system typography, hover
/// motion, shapes, and blue native tint are preserved verbatim from the old
/// AppKit overlay implementation.
public struct ArcoNativeActionButton: View {
    private let title: String
    private let symbol: String
    private let variant: ArcoNativeActionVariant
    private let enabled: Bool
    private let tint: Color
    private let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(
        title: String,
        symbol: String,
        variant: ArcoNativeActionVariant,
        enabled: Bool = true,
        tint: Color = ArcoNativeGlassPalette.action,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.variant = variant
        self.enabled = enabled
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Group {
            if #available(macOS 26.0, *), !accessibilityReduceTransparency {
                GlassEffectContainer(spacing: 8) { nativeAction }
            } else {
                fallbackAction
            }
        }
        .disabled(!enabled)
        .allowsHitTesting(enabled)
    }

    @available(macOS 26.0, *)
    @ViewBuilder private var nativeAction: some View {
        Group {
            switch variant {
            case .toolbar:
                actionButton {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .help(title)
            case .prominent:
                actionButton {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Capsule())
                .background(tint, in: Capsule())
            case .standard:
                actionButton {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
    }

    @ViewBuilder private var fallbackAction: some View {
        switch variant {
        case .toolbar:
            actionButton {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .contentShape(Circle())
            .background(
                accessibilityReduceTransparency
                    ? AnyShapeStyle(ArcoNativeColors.surfaceRaised)
                    : AnyShapeStyle(.regularMaterial),
                in: Circle()
            )
            .overlay(
                Circle().strokeBorder(
                    colorSchemeContrast == .increased
                        ? ArcoNativeColors.inkStrong.opacity(0.42)
                        : .white.opacity(0.28),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                )
            )
            .help(title)
        case .prominent:
            actionButton {
                Label(title, systemImage: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Capsule())
            .background(tint, in: Capsule())
        case .standard:
            actionButton {
                Label(title, systemImage: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Capsule())
            .background(
                accessibilityReduceTransparency
                    ? AnyShapeStyle(ArcoNativeColors.surfaceRaised)
                    : AnyShapeStyle(.regularMaterial),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    colorSchemeContrast == .increased
                        ? ArcoNativeColors.inkStrong.opacity(0.42)
                        : .white.opacity(0.28),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.75
                )
            )
        }
    }

    private func actionButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button(action: action, label: label)
            .buttonStyle(ArcoPressFeedbackButtonStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(title)
    }
}

/// Font construction and the fixed product scale from the original UI.
public enum ArcoTypography {
    public static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static let meetingTitle = sans(28, weight: .semibold)
    public static let conversationHeading = sans(14, weight: .semibold)
    public static let conversationQuestion = sans(13, weight: .semibold)
    public static let conversationBody = sans(13)
    public static let floatingHeading = sans(13, weight: .semibold)
    public static let floatingQuestion = sans(12.5, weight: .semibold)
    public static let floatingBody = sans(12)
    public static let speaker = sans(12, weight: .semibold)
    public static let pageTitle = sans(36, weight: .semibold)
    public static let surfaceTitle = sans(16, weight: .semibold)
    public static let emptyTitle = sans(20, weight: .semibold)
    public static let body = sans(14)
    public static let bodyStrong = sans(14, weight: .medium)
    public static let metadata = sans(12)
    public static let small = sans(12)
    public static let tiny = sans(12)
}

/// The original React surface uses Lucide 1.24.0. Keeping the same 24-point
/// SVG nodes avoids silently swapping product icons for visually different
/// SF Symbols during the native migration.
public enum ArcoLucideSymbol: Sendable {
    case arrowDown
    case arrowLeft
    case arrowUp
    case audioLines
    case audioWaveform
    case bookOpenText
    case bookmark
    case check
    case chevronRight
    case circleAlert
    case copy
    case fileSearch
    case fileText
    case folderOpen
    case info
    case link2
    case pencil
    case plus
    case x

    fileprivate var nodes: String {
        switch self {
        case .arrowDown:
            #"<path d="M12 5v14"/><path d="m19 12-7 7-7-7"/>"#
        case .arrowLeft:
            #"<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>"#
        case .arrowUp:
            #"<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>"#
        case .audioLines:
            #"<path d="M2 10v3"/><path d="M6 6v11"/><path d="M10 3v18"/><path d="M14 8v7"/><path d="M18 5v13"/><path d="M22 10v3"/>"#
        case .audioWaveform:
            #"<path d="M2 13a2 2 0 0 0 2-2V7a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0V4a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0v-4a2 2 0 0 1 2-2"/>"#
        case .bookOpenText:
            #"<path d="M12 7v14"/><path d="M16 12h2"/><path d="M16 8h2"/><path d="M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z"/><path d="M6 12h2"/><path d="M6 8h2"/>"#
        case .bookmark:
            #"<path d="M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z"/>"#
        case .check:
            #"<path d="M20 6 9 17l-5-5"/>"#
        case .chevronRight:
            #"<path d="m9 18 6-6-6-6"/>"#
        case .circleAlert:
            #"<circle cx="12" cy="12" r="10"/><line x1="12" x2="12" y1="8" y2="12"/><line x1="12" x2="12.01" y1="16" y2="16"/>"#
        case .copy:
            #"<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>"#
        case .fileSearch:
            #"<path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/><circle cx="11.5" cy="14.5" r="2.5"/><path d="M13.3 16.3 15 18"/>"#
        case .fileText:
            #"<path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>"#
        case .folderOpen:
            #"<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>"#
        case .info:
            #"<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>"#
        case .link2:
            #"<path d="M9 17H7A5 5 0 0 1 7 7h2"/><path d="M15 7h2a5 5 0 1 1 0 10h-2"/><line x1="8" x2="16" y1="12" y2="12"/>"#
        case .pencil:
            #"<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>"#
        case .plus:
            #"<path d="M5 12h14"/><path d="M12 5v14"/>"#
        case .x:
            #"<path d="M18 6 6 18"/><path d="m6 6 12 12"/>"#
        }
    }
}

public struct ArcoLucideIcon: View {
    public let symbol: ArcoLucideSymbol
    public let size: CGFloat
    public let strokeWidth: CGFloat

    public init(_ symbol: ArcoLucideSymbol, size: CGFloat, strokeWidth: CGFloat = 2) {
        self.symbol = symbol
        self.size = size
        self.strokeWidth = strokeWidth
    }

    public var body: some View {
        Image(nsImage: image)
            .resizable()
            .renderingMode(.template)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var image: NSImage {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="\(strokeWidth)" stroke-linecap="round" stroke-linejoin="round">\(symbol.nodes)</svg>
        """
        let image = svg.data(using: .utf8).flatMap(NSImage.init(data:)) ?? NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = true
        return image
    }
}
