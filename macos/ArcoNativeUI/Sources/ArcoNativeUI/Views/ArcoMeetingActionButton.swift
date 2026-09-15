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
    public let action: @MainActor () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, symbol: String, active: Bool = false, busy: Bool = false,
                failed: Bool = false, compact: Bool = false, iconOnly: Bool = false, statusBadge: String? = nil, action: @escaping @MainActor () -> Void) {
        self.title = title; self.symbol = symbol; self.active = active; self.busy = busy
        self.failed = failed; self.compact = compact; self.iconOnly = iconOnly; self.statusBadge = statusBadge; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView().controlSize(.mini).tint(foreground).frame(width: 14, height: 14)
                } else {
                    Image(systemName: symbol).font(.system(size: iconOnly ? 16 : 14, weight: .medium))
                        .frame(width: iconOnly ? 20 : 16, height: 20)
                }
                if !iconOnly {
                    Text(title).font(ArcoTypography.sans(compact ? 12 : 13, weight: .semibold))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 0 : (compact ? 10 : 12))
            .frame(width: iconOnly ? 36 : nil, height: 36)
            .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if iconOnly, let statusBadge {
                    Image(systemName: statusBadge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(foreground)
                        .background(ArcoNativeColors.surfaceSubtle, in: Circle())
                        .padding(3)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.985))
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ArcoMotion.hover, value: hovering)
        .accessibilityLabel(title)
    }

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
