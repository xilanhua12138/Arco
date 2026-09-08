import SwiftUI

/// Shared by settings pages and their embedded editors, including busy/disabled states.
struct SettingsActionButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        SettingsActionSurface(configuration: configuration, prominent: prominent)
    }
}

private struct SettingsActionSurface: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(ArcoTypography.sans(14))
            .foregroundStyle(prominent ? ArcoNativeColors.surfaceRaised : ArcoNativeColors.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .circular)
                    .fill(prominent
                        ? (hovered && isEnabled ? ArcoNativeColors.actionHover : ArcoNativeColors.inkStrong)
                        : (hovered && isEnabled ? ArcoNativeColors.surfaceHover : ArcoNativeColors.surfaceRaised))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .circular)
                    .strokeBorder(prominent ? Color.clear : ArcoNativeColors.line, lineWidth: 1)
            }
            .contentShape(Capsule(style: .circular))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : ArcoMotion.hover, value: hovered)
    }
}
