import AppKit
import SwiftUI

/// Actual Feishu screenshots. Viewports focus on the controls; screenshot
/// pixels stay unmodified and callouts are separate accessibility-aware views.
public struct MeetingAudioGuideView: View {
    private let translate: ArcoTranslate
    @State private var stage = 0
    public init(translate: @escaping ArcoTranslate = ArcoTranslations.english) {
        self.translate = translate
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(t("meetingAudio.guideTitle")).font(ArcoTypography.bodyStrong)
                Spacer()
                Text(t("meetingAudio.illustration")).font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
            Picker(t("meetingAudio.guideStage"), selection: $stage) {
                Text(t("meetingAudio.beforeMeeting")).tag(0)
                Text(t("meetingAudio.inMeetingGuide")).tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            Text(t("meetingAudio.openArrow")).font(ArcoTypography.bodyStrong)
            if stage == 0 {
                screenshot("feishu-before", crop: CGRect(x: 0.018, y: 0.79, width: 0.68, height: 0.20),
                    highlight: CGRect(x: 0.146, y: 0.897, width: 0.038, height: 0.061))
                    .aspectRatio(4.02, contentMode: .fit)
            } else {
                screenshot("feishu-during", crop: CGRect(x: 0.27, y: 0.83, width: 0.46, height: 0.17),
                    highlight: CGRect(x: 0.333, y: 0.942, width: 0.024, height: 0.043))
                    .aspectRatio(3.69, contentMode: .fit)
            }
            HStack(alignment: .top, spacing: 20) {
                // Focus on the microphone group, excluding unrelated speakers.
                screenshot("feishu-menu", crop: CGRect(x: 0.02, y: 0.24, width: 0.96, height: 0.30),
                    highlight: CGRect(x: 0.075, y: 0.296, width: 0.86, height: 0.086))
                    .aspectRatio(1.735, contentMode: .fit).frame(width: 210)
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("meetingAudio.chooseSystem")).font(ArcoTypography.bodyStrong)
                    Text(t("meetingAudio.automaticSwitchHelp")).font(ArcoTypography.small)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                }.fixedSize(horizontal: false, vertical: true)
            }
            Text(t("meetingAudio.speakerHelp")).font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func screenshot(_ name: String, crop: CGRect, highlight: CGRect) -> some View {
        GeometryReader { geometry in
            if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "MeetingAudioGuide"),
               let image = NSImage(contentsOf: url) {
                let width = geometry.size.width / crop.width
                let height = width * image.size.height / image.size.width
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable().frame(width: width, height: height)
                        .offset(x: -crop.minX * width, y: -crop.minY * height)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: highlight.width * width, height: highlight.height * height)
                        .offset(x: (highlight.minX - crop.minX) * width, y: (highlight.minY - crop.minY) * height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ArcoNativeColors.lineThin))
        .accessibilityHidden(true)
    }
    private func t(_ key: String) -> String { translate(key, [:]) }
}
