import SwiftUI

@_spi(Testing)
public enum ArcoHistoryISO8601 {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let standard = Date.ISO8601FormatStyle()

    public static func parse(_ value: String) -> Date? {
        (try? fractional.parse(value)) ?? (try? standard.parse(value))
    }
}

public struct HistoryPageView: View {
    public var meetings: [MeetingSummary]
    public var selectedMeetingID: String?
    @Binding public var query: String
    public var onSelectMeeting: (String) -> Void
    public var translate: ArcoTranslate
    public var locale: Locale
    public var now: Date
    public var viewportWidth: CGFloat

    @FocusState private var searchFocused: Bool

    public init(
        meetings: [MeetingSummary],
        selectedMeetingID: String?,
        query: Binding<String>,
        viewportWidth: CGFloat,
        locale: Locale = .current,
        now: Date = Date(),
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onSelectMeeting: @escaping (String) -> Void
    ) {
        self.meetings = meetings
        self.selectedMeetingID = selectedMeetingID
        self._query = query
        self.viewportWidth = viewportWidth
        self.locale = locale
        self.now = now
        self.translate = translate
        self.onSelectMeeting = onSelectMeeting
    }

    public var body: some View {
        let meetingGroups = groups
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Text(translate("history.heading", [:]))
                    .font(ArcoTypography.pageTitle)
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                    .tracking(-0.72)
                    .lineLimit(1)
                    .frame(height: 40, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 12)

                searchField
            }

            if meetingGroups.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(meetingGroups) { group in
                            meetingGroup(group)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(translate("history.results", [:]))
            }
        }
        .padding(.top, 32)
        .padding(
            .horizontal,
            ArcoLayoutMetrics.historyPageHorizontalPadding(viewportWidth: viewportWidth)
        )
        .padding(.bottom, 16)
        .frame(maxWidth: 1080, maxHeight: .infinity)
        .background(Color.clear)
    }

    @ViewBuilder
    private var searchField: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                searchContent
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .frame(width: compactLayout ? 220 : 260, height: 36)
        } else {
            searchContent
                .contentShape(Capsule())
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.75))
                .frame(width: compactLayout ? 220 : 260, height: 36)
        }
    }

    private var searchContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                translate("history.searchPlaceholder", [:]),
                text: $query,
                prompt: Text(translate("history.searchPlaceholder", [:]))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .focused($searchFocused)
            .accessibilityLabel(translate("history.search", [:]))

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ArcoNativeColors.surfaceSubtle)
                    .frame(width: 44, height: 44)
                ArcoLucideIcon(.audioLines, size: 22)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
            .accessibilityHidden(true)

            Text(translate("history.noMatches", [:]))
                .font(ArcoTypography.emptyTitle)
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)

            Text(translate("history.noMatchesHelp", [:]))
                .font(ArcoTypography.body)
                .foregroundStyle(ArcoNativeColors.ink)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func meetingGroup(_ group: MeetingGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(translate(group.translationKey, [:]))
                .font(ArcoTypography.metadata)
                .foregroundStyle(ArcoNativeColors.ink)
                .frame(height: 42, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            LazyVStack(spacing: 0) {
                ForEach(group.meetings) { meeting in
                    HistoryMeetingRow(
                        meeting: meeting,
                        isSelected: meeting.id == selectedMeetingID,
                        time: meetingTime(meeting.startedAt),
                        date: meetingDate(meeting.startedAt),
                        duration: formattedDuration(meeting.durationLabel),
                        lineCount: translate(
                            meeting.utteranceCount == 1 ? "history.lineCountOne" : "history.lineCount",
                            ["count": String(meeting.utteranceCount)]
                        ),
                        title: meetingTitle(meeting),
                        preview: meeting.preview.isEmpty
                            ? translate("history.previewFallback", [:])
                            : meeting.preview,
                        showMetadata: !compactLayout,
                        showsDivider: meeting.id != group.meetings.last?.id,
                        onSelect: { onSelectMeeting(meeting.id) }
                    )
                }
            }
            .background(ArcoNativeColors.surfaceDocument)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(ArcoNativeColors.lineThin, lineWidth: 1)
            }
        }
        .padding(.bottom, 16)
    }

    private var groups: [MeetingGroup] {
        let today = Calendar.current.startOfDay(for: now)
        let sixDaysAgo = today.addingTimeInterval(-6 * 24 * 60 * 60)
        var buckets: [MeetingGroup.ID: [MeetingSummary]] = [
            .today: [], .thisWeek: [], .earlier: []
        ]

        for meeting in meetings {
            guard let date = parseISODate(meeting.startedAt) else {
                buckets[.earlier, default: []].append(meeting)
                continue
            }
            if date >= today {
                buckets[.today, default: []].append(meeting)
            } else if date >= sixDaysAgo {
                buckets[.thisWeek, default: []].append(meeting)
            } else {
                buckets[.earlier, default: []].append(meeting)
            }
        }

        return MeetingGroup.ID.allCases.compactMap { id in
            let meetings = buckets[id, default: []]
            return meetings.isEmpty ? nil : MeetingGroup(id: id, meetings: meetings)
        }
    }

    private func parseISODate(_ value: String) -> Date? {
        ArcoHistoryISO8601.parse(value)
    }

    private func meetingTime(_ value: String) -> String {
        guard let date = parseISODate(value) else { return translate("common.unknownTime", [:]) }
        return date.formatted(.dateTime.locale(locale).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
    }

    private func meetingDate(_ value: String) -> String {
        guard let date = parseISODate(value) else { return "" }
        return date.formatted(.dateTime.locale(locale).month(.abbreviated).day())
    }

    private func formattedDuration(_ value: String) -> String {
        let pattern = #"^\s*(\d+)\s*(?:m|min)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value)
        else { return value }
        return translate("history.durationMinutes", ["count": String(Int(value[range]) ?? 0)])
    }

    private func meetingTitle(_ meeting: MeetingSummary) -> String {
        let title = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? translate("common.untitledMeeting", [:]) : title
    }

    private var compactLayout: Bool {
        viewportWidth <= ArcoLayoutMetrics.compactViewportBreakpoint
    }
}

public typealias HistoryPage = HistoryPageView

private struct MeetingGroup: Identifiable {
    enum ID: CaseIterable {
        case today
        case thisWeek
        case earlier
    }

    var id: ID
    var meetings: [MeetingSummary]

    var translationKey: String {
        switch id {
        case .today: "history.group.today"
        case .thisWeek: "history.group.thisWeek"
        case .earlier: "history.group.earlier"
        }
    }
}

private struct HistoryMeetingRow: View {
    var meeting: MeetingSummary
    var isSelected: Bool
    var time: String
    var date: String
    var duration: String
    var lineCount: String
    var title: String
    var preview: String
    var showMetadata: Bool
    var showsDivider: Bool
    var onSelect: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(time)
                        .font(ArcoTypography.metadata)
                        .frame(height: 20, alignment: .leading)
                    Text(date)
                        .font(ArcoTypography.tiny)
                        .frame(height: 14, alignment: .leading)
                }
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .frame(width: 64, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if meeting.isLive {
                            Circle()
                                .fill(ArcoNativeColors.record)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(title)
                            .font(ArcoTypography.bodyStrong)
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                            .lineLimit(1)
                    }
                    .frame(height: 20, alignment: .leading)

                    Text(preview)
                        .font(ArcoTypography.body)
                        .foregroundStyle(ArcoNativeColors.ink)
                        .lineLimit(1)
                        .frame(height: 20, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if showMetadata {
                        Text(duration)
                        Text(lineCount)
                    }
                    ArcoLucideIcon(.chevronRight, size: 17)
                }
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? ArcoNativeColors.surfaceSelected
                    : hovering ? ArcoNativeColors.surfaceHover : Color.clear
            )
            .overlay(alignment: .bottom) {
                if showsDivider { ArcoNativeColors.lineThin.frame(height: 1) }
            }
        }
        .buttonStyle(HistoryMeetingRowButtonStyle())
        .onHover { hovering = $0 }
        .animation(accessibilityReduceMotion ? nil : ArcoMotion.hover, value: hovering)
        .animation(accessibilityReduceMotion ? nil : ArcoMotion.state, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HistoryMeetingRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HistoryMeetingRowButton(configuration: configuration)
    }
}

private struct HistoryMeetingRowButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && isEnabled && !accessibilityReduceMotion ? 0.995 : 1
            )
            .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
            .animation(
                accessibilityReduceMotion ? .easeOut(duration: 0.08) : ArcoMotion.press,
                value: configuration.isPressed
            )
    }
}
