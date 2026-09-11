import AppKit
import SwiftUI

public struct MeetingAudioSetupView: View {
    @ObservedObject private var model: MeetingAudioSetupModel
    private let onboarding: Bool
    private let locked: Bool
    private let translate: ArcoTranslate
    @State private var showGuide = false

    public init(model: MeetingAudioSetupModel, onboarding: Bool = false, locked: Bool = false,
                translate: @escaping ArcoTranslate = ArcoTranslations.english) {
        self.model = model; self.onboarding = onboarding; self.locked = locked; self.translate = translate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2")
                Text(translate("meetingAudio.title", [:])).font(ArcoTypography.bodyStrong)
                if onboarding {
                    Text(translate("meetingAudio.optional", [:]))
                        .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
                }
                Spacer()
            }
            Text(translate("meetingAudio.help", [:]))
                .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: model.state == .ready ? "checkmark.circle" : "mic") }
                Text(translate(statusKey, [:])).font(ArcoTypography.small)
                Spacer()
            }
            .foregroundStyle(model.state == .ready ? ArcoNativeColors.success : ArcoNativeColors.inkMuted)
            if let key = model.errorKey {
                Text(translate(key, [:])).font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.ink).fixedSize(horizontal: false, vertical: true)
            }
            if model.state != .ready && !model.busy && !(onboarding && model.skipped) {
                Text(translate(locked ? "meetingAudio.inMeeting" : "meetingAudio.installHelp", [:]))
                    .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Button {
                        if model.state == .restartRequired { model.refresh() }
                        else { Task { await model.configure() } }
                    } label: {
                        Text(translate(model.state == .restartRequired ? "meetingAudio.recheck" : "meetingAudio.configure", [:]))
                            .font(ArcoTypography.sans(12, weight: .semibold))
                            .foregroundStyle(ArcoNativeColors.actionInk)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(ArcoNativeColors.action, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    .opacity(locked ? 0.45 : 1)
                    if onboarding {
                        Button(translate("meetingAudio.skip", [:])) { model.skip() }
                            .buttonStyle(.plain)
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                    }
                }
                .font(ArcoTypography.small)
            }
            if onboarding && model.skipped && model.state != .ready {
                Button(translate("meetingAudio.configure", [:])) { Task { await model.configure() } }
                    .buttonStyle(.plain).font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.ink).disabled(model.busy || locked)
            }
            if !onboarding {
                Button { showGuide.toggle() } label: {
                    Label(translate("meetingAudio.guideTitle", [:]), systemImage: showGuide ? "chevron.up" : "photo.on.rectangle")
                }
                .buttonStyle(.plain).font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.action)
            }
            if showGuide || (onboarding && model.state == .ready) {
                Divider().padding(.vertical, 2)
                MeetingAudioGuideView(translate: translate)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ArcoNativeColors.lineThin))
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var statusKey: String {
        switch model.state {
        case .ready: "meetingAudio.ready"
        case .downloading: "meetingAudio.downloading"
        case .installing: "meetingAudio.installing"
        case .restartRequired: "meetingAudio.restart"
        case .failed: "meetingAudio.failed"
        case .missing: model.skipped ? "meetingAudio.skipped" : "meetingAudio.missing"
        }
    }
}
