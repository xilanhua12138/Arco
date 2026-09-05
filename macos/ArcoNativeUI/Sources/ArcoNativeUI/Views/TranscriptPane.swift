import AppKit
import SwiftUI

@_spi(Testing)
@MainActor
public enum ArcoSourceTextLayoutMetrics {
    /// CSS `ch` resolves against the inherited 16px root font on these source
    /// containers, even though their child paragraphs use smaller type.
    public static func maximumWidth(characterCount: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 16)
        let zeroWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        return max(0, characterCount) * zeroWidth
    }
}

public enum TranscriptPaneLayout: Sendable {
    case main
    case agentOverlay
}

@_spi(Testing)
public struct TranscriptLiveEdgeRevision: Equatable, Sendable {
    public let lineCount: Int
    public let lastLine: TranscriptLine?

    public init(lines: [TranscriptLine]) {
        lineCount = lines.count
        lastLine = lines.last
    }
}

@_spi(Testing)
public enum TranscriptLiveFollowPolicy {
    public static func shouldFollow(active: Bool, followingLive: Bool) -> Bool {
        active && followingLive
    }
}

public struct TranscriptPaneView: View {
    public var meeting: MeetingDetail?
    public var capture: CaptureState
    public var loading: Bool
    public var compact: Bool
    public var showHeader: Bool
    public var layout: TranscriptPaneLayout
    public var translate: ArcoTranslate

    @State private var followingLive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        meeting: MeetingDetail?,
        capture: CaptureState,
        loading: Bool,
        compact: Bool = false,
        showHeader: Bool = true,
        layout: TranscriptPaneLayout = .main,
        translate: @escaping ArcoTranslate = ArcoTranslations.english
    ) {
        self.meeting = meeting
        self.capture = capture
        self.loading = loading
        self.compact = compact
        self.showHeader = showHeader
        self.layout = layout
        self.translate = translate
    }

    public var body: some View {
        Group {
            if loading {
                loadingState
            } else if let meeting {
                transcript(meeting)
            } else {
                noSelectionState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(layout == .agentOverlay ? Color.clear : ArcoNativeColors.surfaceDocument)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            loading ? translate("transcript.loading", [:]) : translate("transcript.aria", [:])
        )
    }

    private var loadingState: some View {
        VStack(spacing: 0) {
            if showHeader { header }

            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ArcoNativeColors.surfaceSubtle)
                    .frame(width: 96, height: 12)

                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ArcoNativeColors.surfaceSubtle)
                        .frame(width: proxy.size.width * 0.46, height: 34)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 34)
                .padding(.top, 14)
                .padding(.bottom, 24)

                ForEach(0..<6, id: \.self) { _ in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ArcoNativeColors.surfaceSubtle)
                            .frame(width: 64, height: 10)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ArcoNativeColors.surfaceSubtle)
                            .frame(height: 44)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    private var noSelectionState: some View {
        VStack(spacing: 0) {
            if showHeader { header }
            emptyState(
                icon: "doc.text",
                headingKey: "transcript.noneSelected",
                helpKey: "transcript.noneSelectedHelp",
                iconContainer: true
            )
        }
    }

    private var header: some View {
        HStack {
            Text(translate("transcript.heading", [:]))
                .font(ArcoTypography.conversationHeading)
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
    }

    private func transcript(_ meeting: MeetingDetail) -> some View {
        let active = capture.phase == .recording && meeting.summary.id == capture.activeMeetingId
        let generatedSummary = meeting.summary.generatedSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let liveEdgeRevision = TranscriptLiveEdgeRevision(lines: meeting.lines)

        return VStack(spacing: 0) {
            if showHeader { header }

            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if !generatedSummary.isEmpty {
                                MeetingSummaryDocument(
                                    summary: generatedSummary,
                                    compact: compact,
                                    translate: translate
                                )
                            }

                            if meeting.lines.isEmpty {
                                emptyTranscriptState(active: active)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(meeting.lines) { line in
                                        transcriptLine(line)
                                    }

                                    if active && !compact {
                                        ListeningIndicator(label: translate("common.listening", [:]))
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.bottom, compact ? 48 : 0)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("transcript-live-edge")
                                .background {
                                    GeometryReader { edge in
                                        Color.clear.preference(
                                            key: TranscriptBottomPreferenceKey.self,
                                            value: edge.frame(in: .named("transcript-scroll")).maxY
                                        )
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    }
                    .coordinateSpace(name: "transcript-scroll")
                    .onPreferenceChange(TranscriptBottomPreferenceKey.self) { bottom in
                        followingLive = bottom - viewport.size.height < 72
                    }
                    .onAppear {
                        guard active else { return }
                        proxy.scrollTo("transcript-live-edge", anchor: .bottom)
                    }
                    .onChange(of: liveEdgeRevision) {
                        guard TranscriptLiveFollowPolicy.shouldFollow(
                            active: active,
                            followingLive: followingLive
                        ) else { return }
                        if reduceMotion {
                            proxy.scrollTo("transcript-live-edge", anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) {
                                proxy.scrollTo("transcript-live-edge", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: active) {
                        guard active && followingLive else { return }
                        proxy.scrollTo("transcript-live-edge", anchor: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if active && !followingLive {
                            Button {
                                if reduceMotion {
                                    proxy.scrollTo("transcript-live-edge", anchor: .bottom)
                                } else {
                                    withAnimation(.easeOut(duration: 0.22)) {
                                        proxy.scrollTo("transcript-live-edge", anchor: .bottom)
                                    }
                                }
                                followingLive = true
                            } label: {
                                HStack(spacing: 5) {
                                    ArcoLucideIcon(.arrowDown, size: 14)
                                    Text(translate("transcript.jumpToLive", [:]))
                                }
                                .font(ArcoTypography.sans(compact ? 10 : 12))
                                .foregroundStyle(ArcoNativeColors.actionInk)
                                .padding(.horizontal, compact ? 9 : 12)
                                .padding(.vertical, compact ? 7 : 8)
                                .background(ArcoNativeColors.action)
                                .clipShape(Capsule(style: .continuous))
                            }
                            .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.97))
                            .padding(compact ? 10 : 16)
                        }
                    }
                }
            }
        }
    }

    private func transcriptLine(_ line: TranscriptLine) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        speakerLabel(line.speaker, compact: true)
                        Spacer(minLength: 8)
                        Text(line.timestamp)
                            .font(ArcoTypography.mono(10))
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                            .lineLimit(1)
                    }
                    Text(line.text)
                        .font(layout == .agentOverlay ? ArcoTypography.floatingBody : ArcoTypography.sans(13))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .lineSpacing(layout == .agentOverlay ? 2.5 : 3.4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Text(line.timestamp)
                        .font(ArcoTypography.mono(12))
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                        .frame(width: 64, alignment: .leading)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        speakerLabel(line.speaker, compact: false)
                        Text(line.text)
                            .font(ArcoTypography.body)
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                            .lineSpacing(5.2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TranscriptHoverModifier())
        .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
    }

    private func speakerLabel(_ speaker: String, compact: Bool) -> some View {
        let label = localizedSpeakerLabel(speaker)
        let source = speaker.lowercased(with: .current).hasPrefix("remote")
            ? translate("transcript.systemAudio", [:])
            : translate("transcript.roomMic", [:])

        return HStack(spacing: 7) {
            SpeakerAvatarView(index: speakerAvatarIndex(for: speaker), size: compact ? 16 : 18)
            Text(label)
                .font(ArcoTypography.sans(compact ? 11 : 12, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineLimit(1)
        }
        .frame(height: compact ? 16 : 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(source)")
    }

    private func localizedSpeakerLabel(_ speaker: String) -> String {
        let number = speaker.firstMatch(of: /\d+/).map { String($0.output) } ?? "1"
        let normalized = speaker.lowercased(with: .current)
        if normalized.hasPrefix("remote") {
            return translate("transcript.remoteSpeaker", ["number": number])
        }
        if normalized.hasPrefix("in room") {
            return translate("transcript.roomSpeaker", ["number": number])
        }
        return speaker
    }

    private func emptyTranscriptState(active: Bool) -> some View {
        emptyState(
            icon: "waveform",
            headingKey: active ? "transcript.awaitingWords" : "transcript.noTranscript",
            helpKey: active ? "transcript.awaitingWordsHelp" : "transcript.noTranscriptHelp",
            iconContainer: false
        )
    }

    private func emptyState(icon: String, headingKey: String, helpKey: String, iconContainer: Bool) -> some View {
        VStack(spacing: 0) {
            if iconContainer {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ArcoNativeColors.surfaceSubtle)
                        .frame(width: 44, height: 44)
                    transcriptIcon(icon, size: 22)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                }
                .accessibilityHidden(true)
            } else {
                transcriptIcon(icon, size: 24)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .accessibilityHidden(true)
            }
            Text(translate(headingKey, [:]))
                .font(ArcoTypography.sans(compact ? 15 : 20, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            Text(translate(helpKey, [:]))
                .font(ArcoTypography.sans(compact ? 11 : 14))
                .foregroundStyle(ArcoNativeColors.ink)
                .lineSpacing(compact ? 3.8 : 3)
                .frame(maxWidth: compact ? 220 : nil)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func transcriptIcon(_ icon: String, size: CGFloat) -> some View {
        if icon == "doc.text" {
            ArcoLucideIcon(.fileText, size: size)
        } else {
            ArcoLucideIcon(.audioWaveform, size: size)
        }
    }
}

public typealias TranscriptPane = TranscriptPaneView

private struct TranscriptBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TranscriptHoverModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? ArcoNativeColors.surfaceHover : Color.clear)
            .onHover { hovering = $0 }
    }
}

private struct ListeningIndicator: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(ArcoNativeColors.inkMuted).frame(width: 4, height: 4)
            }
            Text(label)
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

private struct MeetingSummaryDocument: View {
    let summary: String
    let compact: Bool
    let translate: ArcoTranslate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(translate("transcript.summary", [:]))
                .font(ArcoTypography.sans(compact ? 12 : 14, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .tracking(compact ? 0 : -0.14)
                .padding(.bottom, compact ? 6 : 10)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                ForEach(Array(SummaryParser.blocks(summary).enumerated()), id: \.offset) { _, block in
                    summaryBlock(block)
                }
            }
            .frame(
                maxWidth: ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: 68),
                alignment: .leading
            )
        }
        .padding(.horizontal, compact ? 11 : 18)
        .padding(.top, compact ? 12 : 18)
        .padding(.bottom, compact ? 14 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("transcript.summaryAria", [:]))
    }

    @ViewBuilder
    private func summaryBlock(_ block: SummaryBlock) -> some View {
        let bodySize: CGFloat = compact ? 13 : 14
        switch block {
        case let .heading(text):
            Text(text)
                .font(ArcoTypography.sans(13, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineSpacing(4.4)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(text)
                .font(ArcoTypography.sans(bodySize))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineSpacing(compact ? 3.4 : 5.2)
                .fixedSize(horizontal: false, vertical: true)
        case let .unordered(items):
            summaryList(items.enumerated().map { ("•", $0.element) }, size: bodySize)
        case let .ordered(items):
            summaryList(items.enumerated().map { ("\($0.offset + 1).", $0.element) }, size: bodySize)
        }
    }

    private func summaryList(_ items: [(String, String)], size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.0).frame(width: 14, alignment: .trailing)
                    Text(item.1).fixedSize(horizontal: false, vertical: true)
                }
                .font(ArcoTypography.sans(size))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineSpacing(compact ? 3.4 : 5.2)
            }
        }
        .padding(.leading, 6)
    }
}

private enum SummaryBlock {
    case heading(String)
    case paragraph(String)
    case unordered([String])
    case ordered([String])
}

private enum SummaryParser {
    static func blocks(_ summary: String) -> [SummaryBlock] {
        var blocks: [SummaryBlock] = []
        var paragraph: [String] = []
        var continuingList = false

        func inline(_ value: String) -> String {
            var result = replacing(value, pattern: #"\*\*([^*]+)\*\*"#, template: "$1")
            result = replacing(result, pattern: #"__([^_]+)__"#, template: "$1")
            result = replacing(result, pattern: #"`([^`]+)`"#, template: "$1")
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(inline(paragraph.joined(separator: " ")))) }
            paragraph = []
        }

        for rawLine in summary.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continuingList = false
                continue
            }
            if let match = match(line, pattern: #"^#{1,6}\s+(.+)$"#) {
                flushParagraph()
                blocks.append(.heading(inline(match)))
                continuingList = false
                continue
            }
            if let value = match(line, pattern: #"^[-*•]\s+(.+)$"#) {
                flushParagraph()
                let item = inline(value)
                if continuingList, case let .unordered(existing) = blocks.last {
                    blocks[blocks.count - 1] = .unordered(existing + [item])
                } else {
                    blocks.append(.unordered([item]))
                }
                continuingList = true
                continue
            }
            if let value = match(line, pattern: #"^\d+[.)]\s+(.+)$"#) {
                flushParagraph()
                let item = inline(value)
                if continuingList, case let .ordered(existing) = blocks.last {
                    blocks[blocks.count - 1] = .ordered(existing + [item])
                } else {
                    blocks.append(.ordered([item]))
                }
                continuingList = true
                continue
            }
            continuingList = false
            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private static func replacing(_ value: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }

    private static func match(_ value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let result = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(result.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }
}
