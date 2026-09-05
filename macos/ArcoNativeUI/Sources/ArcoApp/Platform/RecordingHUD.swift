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
    let onError: @MainActor (Error) -> Void

    init(
        model: RecordingHUDModel,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onToggleAgent: @escaping @MainActor () throws -> Bool,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.model = model
        self.translate = translate
        self.onToggleAgent = onToggleAgent
        self.onError = onError
    }

    var body: some View {
        HStack(spacing: 8) {
            RecordingHUDStatusView(
                model: RecordingHUDStatusState(
                    phase: model.capture.phase,
                    startedAt: model.capture.startedAt,
                    saving: model.saving,
                    saved: model.saved
                ),
                elapsedClock: model.elapsedClock,
                translate: translate
            )
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
                } catch {
                    onError(error)
                }
            } label: {
                Label { Text(translate("hud.askArco", [:])) } icon: {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 15, height: 15)
                }
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
}

private struct RecordingHUDStatusState {
    let phase: CapturePhase
    let startedAt: String?
    let saving: Bool
    let saved: Bool
}

private struct RecordingHUDStatusView: View {
    let model: RecordingHUDStatusState
    let elapsedClock: RecordingHUDElapsedClock
    let translate: ArcoTranslate

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if RecordingHUDPresentation.isRecording(phase: model.phase, saving: model.saving, saved: model.saved) {
                    Circle().fill(ArcoNativeColors.record).frame(width: 7, height: 7)
                } else if model.saved {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.success)
                } else {
                    Circle().fill(ArcoNativeColors.inkMuted).frame(width: 6, height: 6)
                }
            }
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)

            Text(statusText)
                .font(ArcoTypography.sans(12, weight: .semibold))
                .foregroundStyle(HUDSourcePalette.ink)
                                .lineLimit(1)

            if !model.saved,
               !model.saving,
               model.phase == .recording {
                let elapsed = elapsedClock.elapsed(startedAt: model.startedAt)
                Text(elapsed)
                    .font(ArcoTypography.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(HUDSourcePalette.ink.opacity(0.5))
                    .lineLimit(1)
                    .accessibilityLabel(elapsed)
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
              model.phase == .recording else {
            return statusText
        }
        return "\(statusText), \(elapsedClock.elapsed(startedAt: model.startedAt))"
    }

    private var statusText: String {
        if model.saved { return translate("hud.saved", [:]) }
        if model.saving || model.phase == .stopping {
            return translate("common.saving", [:])
        }
        if model.phase == .starting {
            return translate("common.starting", [:])
        }
        if model.phase == .error {
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .foregroundStyle(kind == .stop ? ArcoNativeColors.record : HUDSourcePalette.ink)
            .contentShape(shape)
            .background(background, in: shape)
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovering = $0 }
    }

    private var background: Color {
        switch kind {
        case .stop:
            ArcoNativeColors.record.opacity(hovering || configuration.isPressed ? 0.15 : 0.08)
        case .agent:
            HUDSourcePalette.ink.opacity(hovering || configuration.isPressed ? 0.11 : 0.07)
        }
    }
}
