import ArcoNativeUI
import SwiftUI

private enum HUDSourcePalette {
    static let ink = Color(
        red: 17 / 255,
        green: 17 / 255,
        blue: 17 / 255
    )
}

struct RecordingHUDView: View {
    @Bindable var model: RecordingHUDModel
    let translate: ArcoTranslate
    let onToggleAgent: @MainActor () throws -> Bool

    init(
        model: RecordingHUDModel,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onToggleAgent: @escaping @MainActor () throws -> Bool
    ) {
        self.model = model
        self.translate = translate
        self.onToggleAgent = onToggleAgent
    }

    var body: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 0)
            Rectangle()
                .fill(HUDSourcePalette.ink.opacity(0.09))
                .frame(width: 1, height: 20)
                .accessibilityHidden(true)

            Button {
                Task { await model.stop() }
            } label: {
                Label(translate("common.stop", [:]), systemImage: "stop.fill")
                    .labelStyle(HUDLabelStyle(iconSize: 11))
            }
            .buttonStyle(HUDButtonStyle(kind: .stop))
            .disabled(model.controlsLocked)
            .accessibilityLabel(translate("hud.stop", [:]))

            Button {
                do {
                    _ = try onToggleAgent()
                } catch {}
            } label: {
                Label(translate("hud.askArco", [:]), systemImage: "sparkles")
                    .labelStyle(HUDLabelStyle(iconSize: 14))
            }
            .buttonStyle(HUDButtonStyle(kind: .agent))
            .disabled(model.controlsLocked || model.capture.phase != .recording)
        }
        .padding(.leading, 14)
        .padding(.trailing, 11)
        .frame(width: 368, height: 56)
        .background(ArcoWindowDragRegion())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("hud.controls", [:]))
    }

    private var status: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ArcoNativeColors.record)
                .frame(width: 7, height: 7)
                .background {
                    Circle()
                        .fill(ArcoNativeColors.recordSoft)
                        .frame(width: 13, height: 13)
                }
                .accessibilityHidden(true)

            Text(statusText)
                .font(ArcoTypography.sans(12, weight: .semibold))
                .foregroundStyle(HUDSourcePalette.ink)
                .tracking(-0.12)
                .lineLimit(1)

            if !model.saved,
               !model.saving,
               model.capture.phase == .recording {
                Text(model.elapsed)
                    .font(ArcoTypography.mono(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(HUDSourcePalette.ink.opacity(0.5))
                    .lineLimit(1)
                    .accessibilityLabel(model.elapsed)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var statusAccessibilityLabel: String {
        guard !model.saved,
              !model.saving,
              model.capture.phase == .recording else {
            return statusText
        }
        return "\(statusText), \(model.elapsed)"
    }

    private var statusText: String {
        if model.saved { return translate("hud.saved", [:]) }
        if model.saving || model.capture.phase == .stopping {
            return translate("common.saving", [:])
        }
        if model.capture.phase == .starting {
            return translate("common.starting", [:])
        }
        if model.capture.phase == .error {
            return translate("hud.recordingStopped", [:])
        }
        return translate("common.recording", [:])
    }
}

private struct HUDLabelStyle: LabelStyle {
    var iconSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: iconSize, weight: .semibold))
            configuration.title
                .font(ArcoTypography.sans(12, weight: .medium))
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
    }
}

private struct HUDButtonStyle: ButtonStyle {
    enum Kind { case stop, agent }
    var kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HUDButtonStyleBody(
            configuration: configuration,
            kind: kind,
            enabled: isEnabled
        )
    }
}

private struct HUDButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: HUDButtonStyle.Kind
    let enabled: Bool
    @State private var hovering = false

    @ViewBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if #available(macOS 26.0, *) {
            configuration.label
                .foregroundStyle(kind == .stop ? Color.white : HUDSourcePalette.ink)
                .contentShape(shape)
                .glassEffect(
                    .regular.tint(glassTint).interactive(),
                    in: shape
                )
                .opacity(enabled ? 1 : 0.42)
                .onHover { hovering = $0 }
        } else {
            configuration.label
                .foregroundStyle(kind == .stop ? Color.white : HUDSourcePalette.ink)
                .background(background)
                .clipShape(shape)
                .opacity(enabled ? 1 : 0.42)
                .onHover { hovering = $0 }
        }
    }

    private var glassTint: Color {
        switch kind {
        case .stop:
            HUDSourcePalette.ink.opacity(hovering || configuration.isPressed ? 1 : 0.92)
        case .agent:
            HUDSourcePalette.ink.opacity(hovering || configuration.isPressed ? 0.11 : 0.07)
        }
    }

    private var background: Color {
        switch kind {
        case .stop:
            HUDSourcePalette.ink.opacity(hovering || configuration.isPressed ? 1 : 0.92)
        case .agent:
            HUDSourcePalette.ink.opacity(hovering || configuration.isPressed ? 0.11 : 0.07)
        }
    }
}
