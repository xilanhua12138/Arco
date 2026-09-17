import SwiftUI

public struct MeetingPromptView: View {
    public var meeting: DetectedMeeting
    public var translate: ArcoTranslate
    public var onStart: () async -> Bool
    public var onDismiss: () -> Void

    @State private var starting = false
    @State private var startFailed = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        meeting: DetectedMeeting,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onStart: @escaping () async -> Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.translate = translate
        self.onStart = onStart
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(translate(startFailed ? "meetingPrompt.startFailed" : "meetingPrompt.title", [:]))
                .font(ArcoTypography.sans(14, weight: .semibold))
                .foregroundStyle(startFailed ? ArcoNativeColors.record : ArcoNativeColors.inkStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, minHeight: 22)
                .overlay(alignment: .leading) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.brand)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                .overlay {
                    ArcoWindowDragRegion()
                        .accessibilityHidden(true)
                }

            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Text(translate("meetingPrompt.notThisTime", [:]))
                        .font(ArcoTypography.sans(13, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(ArcoNativeColors.surfaceRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(ArcoNativeColors.inkStrong.opacity(0.22), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle())
                .disabled(starting)

                ArcoNativeActionButton(
                    title: translate(
                        starting ? "meetingPrompt.starting" : "meetingPrompt.start",
                        [:]
                    ),
                    symbol: starting ? "ellipsis" : "record.circle",
                    variant: .prominent,
                    enabled: !starting,
                    action: beginCapture
                )
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 320, height: 112)
        .animation(accessibilityReduceMotion ? nil : ArcoMotion.state, value: startFailed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(translate("meetingPrompt.title", [:])). \(promptContext)"
        )
    }

    private var promptContext: String {
        if startFailed { return translate("meetingPrompt.startFailed", [:]) }
        return translate(
            meeting.source == .googleMeet
                ? "meetingPrompt.context.googleMeet"
                : "meetingPrompt.context.feishu",
            [:]
        )
    }

    private func beginCapture() {
        guard !starting else { return }
        starting = true
        startFailed = false
        Task { @MainActor in
            let succeeded = await onStart()
            guard !succeeded else { return }
            starting = false
            startFailed = true
        }
    }
}
