import AppKit
import SwiftUI

/// Text questions and voice participation are independent peer actions.
public struct ArcoMeetingActionButton: View {
    public let title: String
    public let symbol: String
    public var active = false
    public var busy = false
    public var failed = false
    public var compact = false
    public var iconOnly = false
    public var statusBadge: String?
    public var revealLabel = false
    public var revealWidth: CGFloat?
    public var onRevealInteraction: (@MainActor (Bool) -> Void)?
    public let action: @MainActor () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, symbol: String, active: Bool = false, busy: Bool = false,
                failed: Bool = false, compact: Bool = false, iconOnly: Bool = false, statusBadge: String? = nil, revealLabel: Bool = false, revealWidth: CGFloat? = nil,
                onRevealInteraction: (@MainActor (Bool) -> Void)? = nil, action: @escaping @MainActor () -> Void) {
        self.title = title; self.symbol = symbol; self.active = active; self.busy = busy
        self.failed = failed; self.compact = compact; self.iconOnly = iconOnly; self.statusBadge = statusBadge; self.action = action
        self.revealLabel = revealLabel; self.revealWidth = revealWidth; self.onRevealInteraction = onRevealInteraction
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: iconOnly ? 0 : 7) {
                Group {
                    if busy {
                        ProgressView().controlSize(.mini).tint(foreground).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: symbol).font(.system(size: iconOnly ? 16 : 14, weight: .medium))
                            .frame(width: iconOnly ? 20 : 16, height: 20)
                    }
                }
                .frame(width: iconOnly ? 36 : 16, height: 36)
                if iconOnly {
                    Text(title).font(ArcoTypography.sans(compact ? 12 : 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: max(0, labelWidth - 10), alignment: .leading)
                        .padding(.trailing, 10)
                        .frame(width: revealLabel ? labelWidth : 0, alignment: .leading)
                        .clipped()
                        .opacity(revealLabel ? 1 : 0)
                        .accessibilityHidden(true)
                } else {
                    Text(title).font(ArcoTypography.sans(compact ? 12 : 13, weight: .semibold))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 0 : (compact ? 10 : 12))
            .frame(height: 36)
            .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if iconOnly, let statusBadge {
                    Image(systemName: statusBadge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(foreground)
                        .background(ArcoNativeColors.surfaceSubtle, in: Circle())
                        .offset(x: 24, y: -3)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.985))
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ArcoMotion.hover, value: hovering)
        .modifier(ArcoRevealInteraction(onInteraction: onRevealInteraction))
        .accessibilityLabel(title)
    }

    public static func labelRevealWidth(_ title: String, compact: Bool = true) -> CGFloat {
        let font = NSFont.systemFont(ofSize: compact ? 12 : 13, weight: .semibold)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 10
    }

    private var labelWidth: CGFloat { revealWidth ?? Self.labelRevealWidth(title, compact: compact) }

    private var foreground: Color {
        if failed { return ArcoNativeColors.warning }
        if active || busy { return ArcoNativeColors.action }
        return ArcoNativeColors.inkStrong
    }

    private var fill: Color {
        if failed { return ArcoNativeColors.warning.opacity(hovering ? 0.14 : 0.08) }
        if active || busy { return ArcoNativeColors.action.opacity(hovering ? 0.14 : 0.08) }
        return ArcoNativeColors.inkStrong.opacity(hovering ? 0.09 : (iconOnly ? 0.04 : 0.05))
    }
}

private struct ArcoRevealInteraction: ViewModifier {
    let onInteraction: (@MainActor (Bool) -> Void)?
    @State private var hovering = false
    @FocusState private var focused: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if let onInteraction {
            content
                .focused($focused)
                .onHover { hovering = $0 }
                .onChange(of: hovering || focused) { _, engaged in onInteraction(engaged) }
        } else {
            content
        }
    }
}
