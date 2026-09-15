import SwiftUI

/// Text questions and voice participation are independent peer actions.
public struct ArcoMeetingActionButton: View {
    public let title: String
    public let symbol: String
    public var active = false
    public var busy = false
    public var failed = false
    public var compact = false
    public let action: @MainActor () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, symbol: String, active: Bool = false, busy: Bool = false,
                failed: Bool = false, compact: Bool = false, action: @escaping @MainActor () -> Void) {
        self.title = title; self.symbol = symbol; self.active = active; self.busy = busy
        self.failed = failed; self.compact = compact; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView().controlSize(.mini).tint(.white).frame(width: 14, height: 14)
                } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                        .frame(width: 16, height: 16)
                }
                Text(title).font(ArcoTypography.sans(compact ? 12 : 13, weight: .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(ArcoNativeColors.actionInk)
            .frame(width: compact ? 130 : 150, height: compact ? 34 : 36)
            .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.985))
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ArcoMotion.hover, value: hovering)
        .accessibilityLabel(title)
    }

    private var fill: Color {
        if failed { return ArcoNativeColors.warning }
        if active { return hovering ? ArcoNativeColors.actionHover : ArcoNativeColors.action }
        return hovering ? ArcoNativeColors.ink : ArcoNativeColors.inkStrong
    }
}
