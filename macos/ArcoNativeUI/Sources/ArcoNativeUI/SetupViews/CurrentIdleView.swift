import SwiftUI

public struct CurrentMeetingStatistics: Equatable, Sendable {
    public var meetingCount: Int
    public var totalMinutes: Int
    public var transcriptLineCount: Int

    public static func summarize(_ meetings: [MeetingSummary]) -> CurrentMeetingStatistics {
        meetings.reduce(CurrentMeetingStatistics(meetingCount: 0, totalMinutes: 0, transcriptLineCount: 0)) { result, meeting in
            CurrentMeetingStatistics(
                meetingCount: result.meetingCount + 1,
                totalMinutes: result.totalMinutes + durationMinutes(meeting.durationLabel),
                transcriptLineCount: result.transcriptLineCount + meeting.utteranceCount
            )
        }
    }

    private static func durationMinutes(_ label: String) -> Int {
        let pattern = #"^(?:(\d+)\s*h(?:r|rs)?\s*)?(?:(\d+)\s*(?:m|min|mins|minutes?))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range), match.range.location != NSNotFound else { return 0 }
        func number(_ index: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: trimmed) else { return 0 }
            return Int(trimmed[swiftRange]) ?? 0
        }
        let hours = number(1)
        let minutes = number(2)
        return hours == 0 && minutes == 0 && !trimmed.contains("0") ? 0 : hours * 60 + minutes
    }
}

public struct CurrentIdleView: View {
    public var capture: CaptureState
    public var meetings: [MeetingSummary]
    public var audioMode: AudioMode
    public var shortcut: ListeningShortcut?
    public var initializing: Bool
    public var viewportWidth: CGFloat
    public var translate: ArcoTranslate
    public var onStart: () -> Void
    public var onOpenAudioSettings: () -> Void

    @State private var audioSettingsHovering = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        capture: CaptureState,
        meetings: [MeetingSummary],
        audioMode: AudioMode,
        shortcut: ListeningShortcut?,
        initializing: Bool = false,
        viewportWidth: CGFloat,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onStart: @escaping () -> Void,
        onOpenAudioSettings: @escaping () -> Void
    ) {
        self.capture = capture
        self.meetings = meetings
        self.audioMode = audioMode
        self.shortcut = shortcut
        self.initializing = initializing
        self.viewportWidth = viewportWidth
        self.translate = translate
        self.onStart = onStart
        self.onOpenAudioSettings = onOpenAudioSettings
    }

    public var body: some View {
        GeometryReader { geometry in
            let compact = viewportWidth <= ArcoLayoutMetrics.idleStackedViewportBreakpoint
            let horizontalPadding: CGFloat = compact
                ? 28
                : viewportWidth <= ArcoLayoutMetrics.idleMediumViewportBreakpoint ? 44 : 64
            let topPadding: CGFloat = compact ? 38 : 54
            let bottomPadding: CGFloat = compact ? 32 : 46
            let availableHeight = max(0, geometry.size.height - topPadding - bottomPadding)

            ScrollView {
                VStack(spacing: 28) {
                    hero
                        .frame(minHeight: compact ? 230 : 250)
                        .frame(maxHeight: .infinity)

                    if compact {
                        VStack(spacing: 12) {
                            statistics
                            shortcuts
                        }
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            statistics
                            shortcuts.frame(width: 280)
                        }
                    }
                }
                .frame(maxWidth: 900, minHeight: availableHeight)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("capture.idleTitle", [:]))
    }

    private var hero: some View {
        let compact = viewportWidth <= ArcoLayoutMetrics.idleStackedViewportBreakpoint
        let titleSize: CGFloat = compact ? 30 : 36
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array([10, 20, 30, 38, 30, 20, 10].enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(ArcoNativeColors.brand.opacity(0.72))
                        .frame(width: 3, height: CGFloat(height))
                }
            }
            .frame(height: 38)
            .padding(.bottom, 16)
            .accessibilityHidden(true)

            Text(translate("capture.homeTitle", [:]))
                .font(.system(size: titleSize, weight: .semibold, design: .default))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .tracking(compact ? -0.60 : -0.90)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 22)

            VStack(spacing: 8) {
                ArcoNativeActionButton(
                    title: startLabel,
                    symbol: "waveform",
                    variant: .prominent,
                    enabled: !initializing && !busy,
                    action: onStart
                )
                .frame(minWidth: 142, minHeight: 44, maxHeight: 44)
                .fixedSize(horizontal: true, vertical: false)

                if shortcut != nil {
                    shortcutHeroHint
                        .padding(.bottom, 1)
                }

                Button(action: onOpenAudioSettings) {
                    Label(audioLabel, systemImage: "slider.horizontal.3")
                        .font(ArcoTypography.small)
                        .foregroundStyle(audioSettingsHovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 34)
                        .background(
                            audioSettingsHovering ? ArcoNativeColors.surfaceHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.97))
                .onHover { audioSettingsHovering = $0 }
                .animation(
                    accessibilityReduceMotion ? nil : ArcoMotion.hover,
                    value: audioSettingsHovering
                )
                .accessibilityLabel(translate("capture.nextMeetingAudio", [:]))
            }
            .frame(minHeight: 46)

            Label(translate("capture.idleSavedToHistory", [:]), systemImage: "lock")
                .font(ArcoTypography.tiny)
                .foregroundStyle(ArcoNativeColors.inkFaint)
                .labelStyle(ArcoTightLabelStyle(spacing: 5, iconSize: 12))
                .padding(.top, 14)
        }
        .frame(maxWidth: 900, maxHeight: .infinity)
    }

    private var statistics: some View {
        let stats = CurrentMeetingStatistics.summarize(meetings)
        return ArcoGlassSurface(cornerRadius: 18, tone: .neutral) {
            VStack(alignment: .leading, spacing: 22) {
                Text(translate("capture.statsHeading", [:]))
                    .font(ArcoTypography.sans(12, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .frame(height: 17, alignment: .topLeading)

                GeometryReader { geometry in
                    let usableWidth = max(0, geometry.size.width - 40)
                    HStack(alignment: .top, spacing: 20) {
                        statistic("clock.arrow.circlepath", "capture.statsMeetings", stats.meetingCount.formatted())
                            .frame(width: usableWidth * 0.8 / 3.25, alignment: .leading)
                        statistic("clock", "capture.statsListeningTime", listeningTime(stats.totalMinutes))
                            .frame(width: usableWidth * 1.45 / 3.25, alignment: .leading)
                        statistic("text.bubble", "capture.statsTranscriptLines", stats.transcriptLineCount.formatted())
                            .frame(width: usableWidth / 3.25, alignment: .leading)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("capture.statsHeading", [:]))
    }

    private var shortcuts: some View {
        ArcoGlassSurface(cornerRadius: 18, tone: .elevated) {
            VStack(alignment: .leading, spacing: 22) {
                Text(translate("capture.shortcutsHeading", [:]))
                    .font(ArcoTypography.sans(12, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .frame(height: 17, alignment: .topLeading)
                VStack(spacing: 11) {
                    shortcutRow("waveform", "capture.shortcutStartStop", keycaps: listeningKeycaps)
                    shortcutRow("magnifyingglass", "capture.shortcutSearchHistory", keycaps: ["⌘", "K"])
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("capture.shortcutsHeading", [:]))
    }

    private var shortcutHeroHint: some View {
        HStack(spacing: 8) {
            Text(translate("capture.shortcutHeroHint", [:]))
                .font(ArcoTypography.small.weight(.medium))
                .foregroundStyle(ArcoNativeColors.inkMuted)
            HStack(spacing: 4) {
                ForEach(Array(listeningKeycaps.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(ArcoTypography.sans(10, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 25, minHeight: 24)
                        .background(
                            ArcoNativeColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(ArcoNativeColors.lineStrong, lineWidth: 0.75)
                        )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(
            ArcoNativeColors.brandSoft,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(translate("capture.shortcutHeroHint", [:])) \(shortcut?.displayValue ?? "")"
        )
    }

    private func statistic(_ symbol: String, _ titleKey: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(translate(titleKey, [:]), systemImage: symbol)
                .font(ArcoTypography.tiny)
                .foregroundStyle(ArcoNativeColors.inkFaint)
                .labelStyle(ArcoTightLabelStyle(spacing: 6, iconSize: 15))
                .frame(height: 15, alignment: .leading)
            Text(value)
                .font(ArcoTypography.sans(22, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .monospacedDigit()
                .tracking(-0.44)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(_ symbol: String, _ titleKey: String, keycaps: [String]) -> some View {
        HStack(spacing: 12) {
            Label(translate(titleKey, [:]), systemImage: symbol)
                .font(ArcoTypography.tiny)
                .foregroundStyle(ArcoNativeColors.inkFaint)
                .labelStyle(ArcoTightLabelStyle(spacing: 7, iconSize: 14))
                .frame(height: 28)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                ForEach(Array(keycaps.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .font(ArcoTypography.sans(11, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 29, minHeight: 28)
                        .background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.10)))
                        .shadow(color: Color.black.opacity(0.08), radius: 0.5, y: 1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }

    private var busy: Bool { capture.phase == .starting || capture.phase == .stopping }

    private var startLabel: String {
        if initializing { return translate("common.loading", [:]) }
        if capture.phase == .stopping { return translate("common.stopping", [:]) }
        if capture.phase == .starting { return translate("common.starting", [:]) }
        return translate("capture.start", [:])
    }

    private var audioLabel: String {
        switch audioMode {
        case .both: translate("capture.audio.hybrid", [:])
        case .system: translate("capture.audio.online", [:])
        case .mic: translate("capture.audio.room", [:])
        }
    }

    private var listeningKeycaps: [String] {
        shortcut?.displayValue
            .split(separator: " ")
            .map { $0 == "fn" ? "Fn" : String($0) }
            ?? [translate("shortcut.off", [:])]
    }

    private func listeningTime(_ totalMinutes: Int) -> String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return translate("capture.statsHoursMinutes", ["hours": "\(hours)", "minutes": "\(minutes)"])
        }
        return translate("capture.statsMinutes", ["minutes": "\(minutes)"])
    }
}

private struct ArcoTightLabelStyle: LabelStyle {
    var spacing: CGFloat
    var iconSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
                .font(.system(size: iconSize))
                .frame(width: iconSize, height: iconSize)
            configuration.title
        }
    }
}
