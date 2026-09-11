import SwiftUI

public struct ArcoVoicePresence: View {
    public let status: GPTLiveSessionStatus
    public let translate: ArcoTranslate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(status: GPTLiveSessionStatus, translate: @escaping ArcoTranslate) {
        self.status = status
        self.translate = translate
    }
    public var body: some View {
        VStack(spacing: 0) {
            LiveKitAuraView(status: status, reduceMotion: reduceMotion)
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
            Text(translate(statusKey, [:]))
                .font(ArcoTypography.sans(16, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
                .contentTransition(.opacity)
            Text(translate(status.phase == .idle ? "agent.voiceInvitationHint" : "agent.voiceWakeHint", [:]))
                .font(ArcoTypography.sans(11))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 6)
            if let message = status.message, status.phase == .failed {
                Text(message).font(ArcoTypography.sans(11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2).padding(.horizontal, 18).padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("agent.voicePresence", [:]))
    }
    private var statusKey: String {
        switch status.phase {
        case .idle: "agent.voiceReady"
        case .connecting: "agent.voiceJoining"
        case .disconnecting: "agent.voiceLeaving"
        case .failed: "agent.voiceFailed"
        case .connected:
            switch status.activity {
            case .listening: "agent.voiceListening"
            case .thinking: "agent.voiceThinking"
            case .speaking: "agent.voiceSpeaking"
            }
        }
    }
}
