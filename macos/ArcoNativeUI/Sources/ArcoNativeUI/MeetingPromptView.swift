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
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.brand)
                    .frame(width: 32, height: 32)
                    .background(ArcoNativeColors.brandSoft, in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(translate("meetingPrompt.title", [:]))
                        .font(ArcoTypography.sans(15, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                    Text(promptContext)
                        .font(ArcoTypography.metadata)
                        .foregroundStyle(
                            startFailed ? ArcoNativeColors.record : ArcoNativeColors.inkMuted
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(translate("meetingPrompt.notThisTime", [:]), action: onDismiss)
                    .buttonStyle(.plain)
                    .font(ArcoTypography.metadata.weight(.medium))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(starting)

                Spacer(minLength: 8)

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
                .frame(width: 132, height: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 372, height: 140)
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
