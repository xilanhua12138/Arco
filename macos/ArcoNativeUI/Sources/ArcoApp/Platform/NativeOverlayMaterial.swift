import ArcoNativeUI
import SwiftUI

enum ArcoOverlayKind {
    case hud
    case agent

    var cornerRadius: CGFloat {
        switch self {
        case .hud: 14
        case .agent: 16
        }
    }
}

/// The HUD and Agent window are SwiftUI surfaces. AppKit only owns their
/// borderless panel lifecycle; the visible material is rendered here with
/// SwiftUI Liquid Glass instead of the old `window-vibrancy` view hierarchy.
struct SwiftUIOverlayGlassSurface<Content: View>: View {
    let kind: ArcoOverlayKind
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: kind.cornerRadius,
            style: .continuous
        )

        Group {
            if reduceTransparency {
                content.background(reducedTransparencyColor, in: shape)
            } else if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    content
                        .contentShape(shape)
                        .glassEffect(.regular, in: shape)
                }
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(
                        shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75)
                    )
            }
        }
        .clipShape(shape)
        .modifier(OverlayActiveAppearanceModifier())
    }

    private var reducedTransparencyColor: Color {
        switch kind {
        case .hud:
            Color(red: 244 / 255, green: 244 / 255, blue: 244 / 255)
        case .agent:
            ArcoNativeColors.surfaceDocument
        }
    }
}

private struct OverlayActiveAppearanceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.environment(\.appearsActive, true)
        } else {
            content.environment(\.controlActiveState, .key)
        }
    }
}
