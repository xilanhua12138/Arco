import AppKit
import SwiftUI

@_spi(Testing)
public enum TopBarSourceLayout {
    public static let headerHeight: CGFloat = 34
    public static let editingTitleViewportFraction: CGFloat = 0.64
    public static let maximumEditingTitleWidth: CGFloat = 720

    public static func editingTitleWidth(viewportWidth: CGFloat) -> CGFloat {
        min(maximumEditingTitleWidth, max(0, viewportWidth) * editingTitleViewportFraction)
    }
}

@_spi(Testing)
public enum TopBarDetailsLayout {
    public static let triggerSize: CGFloat = 32
    public static let triggerTopInset = (TopBarSourceLayout.headerHeight - triggerSize) / 2
    public static let gap: CGFloat = 8
    public static let maximumWidth: CGFloat = 320
    public static let viewportMargin: CGFloat = 48
    public static let verticalOffset = triggerTopInset + triggerSize + gap

    public static func width(availableWidth: CGFloat) -> CGFloat {
        min(maximumWidth, max(0, availableWidth - viewportMargin))
    }
}

@MainActor
public final class TopBarViewModel: ObservableObject {
    @Published public private(set) var editingMeetingID: String?
    @Published public var titleDraft = ""
    @Published public private(set) var savingTitle = false
    @Published public var detailsMeetingID: String?

    private var titleSaveInFlight = false
    private let onRenameMeeting: (String, String?) async -> Bool

    public init(onRenameMeeting: @escaping (String, String?) async -> Bool) {
        self.onRenameMeeting = onRenameMeeting
    }

    public func isEditing(_ meeting: MeetingSummary?) -> Bool {
        meeting.map { editingMeetingID == $0.id } ?? false
    }

    public func beginEditing(_ meeting: MeetingSummary) {
        titleDraft = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        editingMeetingID = meeting.id
    }

    public func cancelEditing() {
        editingMeetingID = nil
        titleDraft = ""
    }

    @discardableResult
    public func commitTitle(for meeting: MeetingSummary) async -> Bool {
        guard editingMeetingID == meeting.id, !titleSaveInFlight else { return false }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = trimmed.isEmpty ? nil : trimmed
        let current = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrent: String? = current?.isEmpty == false ? current : nil
        if normalized == normalizedCurrent {
            cancelEditing()
            return true
        }

        titleSaveInFlight = true
        savingTitle = true
        let saved = await onRenameMeeting(meeting.id, normalized)
        titleSaveInFlight = false
        savingTitle = false
        if saved { cancelEditing() }
        return saved
    }

    public func toggleDetails(for meeting: MeetingSummary) {
        detailsMeetingID = detailsMeetingID == meeting.id ? nil : meeting.id
    }
}

public struct TopBarView: View {
    public var meeting: MeetingSummary?
    public var meetingDetail: MeetingDetail?
    public var capture: CaptureState
    public var translate: ArcoTranslate
    public var onBackToHistory: (() -> Void)?

    @ObservedObject private var viewModel: TopBarViewModel
    @FocusState private var titleFocused: Bool
    @FocusState private var titleTriggerFocused: Bool
    @FocusState private var detailsFocused: Bool
    @State private var backHovering = false
    @State private var titleHovering = false
    @State private var detailsHovering = false
    @State private var titleCommitInProgress = false
    @State private var pathCopied = false
    @State private var availableWidth: CGFloat = TopBarDetailsLayout.maximumWidth + TopBarDetailsLayout.viewportMargin
    @State private var viewportWidth: CGFloat = TopBarSourceLayout.maximumEditingTitleWidth
        / TopBarSourceLayout.editingTitleViewportFraction
    @StateObject private var detailsInteractionMonitor = TopBarOutsideInteractionMonitor()
    @StateObject private var titleInteractionMonitor = TopBarOutsideInteractionMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        meeting: MeetingSummary?,
        meetingDetail: MeetingDetail? = nil,
        capture: CaptureState,
        viewModel: TopBarViewModel,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onBackToHistory: (() -> Void)? = nil
    ) {
        self.meeting = meeting
        self.meetingDetail = meetingDetail
        self.capture = capture
        self.viewModel = viewModel
        self.translate = translate
        self.onBackToHistory = onBackToHistory
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                if let onBackToHistory {
                    Button(action: onBackToHistory) {
                        ArcoLucideIcon(.arrowLeft, size: 18)
                            .frame(width: 32, height: 32)
                            .background(
                                backHovering ? ArcoNativeColors.surfaceHover : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.94))
                    .foregroundStyle(backHovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                    .onHover { backHovering = $0 }
                    .animation(reduceMotion ? nil : ArcoMotion.hover, value: backHovering)
                    .accessibilityLabel(translate("history.back", [:]))
                    .help(translate("history.back", [:]))
                }

                title

                if recording {
                    HStack(spacing: 5) {
                        Circle().fill(ArcoNativeColors.record).frame(width: 6, height: 6)
                        Text(translate("common.listening", [:]))
                            .font(ArcoTypography.sans(12, weight: .medium))
                            .foregroundStyle(ArcoNativeColors.record)
                            .frame(height: 18)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(translate("topbar.recordingStatus", [:]))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let meeting {
                Button {
                    viewModel.toggleDetails(for: meeting)
                } label: {
                    ArcoLucideIcon(.info, size: 17)
                        .frame(width: 32, height: 32)
                        .background(
                            viewModel.detailsMeetingID == meeting.id
                                ? ArcoNativeColors.surfaceSelected
                                : detailsHovering ? ArcoNativeColors.surfaceHover : .clear,
                            in: Circle()
                        )
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.94))
                .foregroundStyle(
                    detailsHovering || viewModel.detailsMeetingID == meeting.id
                        ? ArcoNativeColors.inkStrong
                        : ArcoNativeColors.inkMuted
                )
                .onHover { detailsHovering = $0 }
                .animation(reduceMotion ? nil : ArcoMotion.hover, value: detailsHovering)
                .focused($detailsFocused)
                .background(TopBarInteractionRegion(monitor: detailsInteractionMonitor))
                .accessibilityLabel(translate("topbar.meetingDetails", [:]))
                .help(translate("topbar.meetingDetails", [:]))
            }
        }
        .frame(minHeight: TopBarSourceLayout.headerHeight)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TopBarWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .background {
            TopBarViewportWidthReader(width: $viewportWidth)
                .allowsHitTesting(false)
        }
        .onPreferenceChange(TopBarWidthPreferenceKey.self) { availableWidth = $0 }
        .overlay(alignment: .topTrailing) {
            if let meeting, detailsOpen(for: meeting) {
                meetingDetails(
                    meeting,
                    width: TopBarDetailsLayout.width(availableWidth: availableWidth)
                )
                .background(TopBarInteractionRegion(monitor: detailsInteractionMonitor))
                .offset(y: TopBarDetailsLayout.verticalOffset)
                .transition(
                    .offset(y: -2)
                        .combined(with: .scale(scale: 0.985, anchor: .topTrailing))
                        .combined(with: .opacity)
                )
                .zIndex(10)
            }
        }
        .animation(reduceMotion ? nil : ArcoMotion.state, value: viewModel.detailsMeetingID)
        .onChange(of: viewModel.detailsMeetingID) { _, value in
            updateDetailsInteractionMonitor(open: value != nil)
        }
        .onChange(of: viewModel.editingMeetingID) { _, editingMeetingID in
            guard let meeting, editingMeetingID == meeting.id else {
                titleInteractionMonitor.deactivate()
                return
            }
            updateTitleInteractionMonitor(for: meeting)
        }
        .onAppear {
            updateDetailsInteractionMonitor(open: viewModel.detailsMeetingID != nil)
            if let meeting, viewModel.isEditing(meeting) {
                updateTitleInteractionMonitor(for: meeting)
            }
        }
        .onDisappear {
            detailsInteractionMonitor.deactivate()
            titleInteractionMonitor.deactivate()
        }
    }

    @ViewBuilder
    private var title: some View {
        if let meeting {
            if viewModel.isEditing(meeting) {
                TextField(
                    translate("topbar.meetingTitle", [:]),
                    text: $viewModel.titleDraft
                )
                .textFieldStyle(.plain)
                .font(currentTitleFont)
                .tracking(-0.504)
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .disabled(viewModel.savingTitle)
                .focused($titleFocused)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(maxWidth: TopBarSourceLayout.editingTitleWidth(viewportWidth: viewportWidth))
                .background(Color.white.opacity(0.6724), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .background(TopBarInteractionRegion(monitor: titleInteractionMonitor))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            titleFocused ? ArcoNativeColors.brand.opacity(0.42) : ArcoNativeColors.inkStrong.opacity(0.15),
                            lineWidth: 1
                        )
                }
                .overlay {
                    if titleFocused {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(ArcoNativeColors.brand.opacity(0.10), lineWidth: 3)
                            .padding(-3)
                    }
                }
                .shadow(color: Color.black.opacity(titleFocused ? 0.07 : 0.06), radius: titleFocused ? 10 : 9, y: titleFocused ? 6 : 5)
                .padding(.horizontal, -8)
                .padding(.vertical, -5)
                .onAppear {
                    titleFocused = true
                    updateTitleInteractionMonitor(for: meeting)
                    DispatchQueue.main.async {
                        (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                    }
                }
                .onDisappear {
                    titleInteractionMonitor.deactivate()
                }
                .onChange(of: viewModel.titleDraft) { _, value in
                    if value.count > 80 { viewModel.titleDraft = String(value.prefix(80)) }
                }
                .onSubmit {
                    commitEditingTitle(for: meeting)
                }
                .onChange(of: titleFocused) { _, focused in
                    if !focused, viewModel.isEditing(meeting) {
                        commitEditingTitle(for: meeting)
                    }
                }
                .onExitCommand {
                    viewModel.cancelEditing()
                    titleFocused = false
                    titleTriggerFocused = true
                }
                .accessibilityLabel(translate("topbar.meetingTitle", [:]))
            } else {
                Button {
                    viewModel.beginEditing(meeting)
                    titleFocused = true
                } label: {
                    ZStack(alignment: .trailing) {
                        Text(displayTitle)
                            .font(currentTitleFont)
                            .tracking(-0.504)
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                            .lineLimit(1)
                            .padding(.trailing, 24)

                        ArcoLucideIcon(.pencil, size: 15)
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                            .opacity(titleHovering || titleTriggerFocused ? 0.48 : 0)
                            .offset(x: titleHovering || titleTriggerFocused ? 0 : -3)
                            .animation(
                                reduceMotion ? nil : ArcoMotion.hover,
                                value: titleHovering || titleTriggerFocused
                            )
                    }
                    .frame(height: 34)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        titleHovering || titleTriggerFocused
                            ? ArcoNativeColors.surfaceHover.opacity(0.72)
                            : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.985))
                .focused($titleTriggerFocused)
                .onHover { titleHovering = $0 }
                .padding(.horizontal, -7)
                .padding(.vertical, -4)
                .accessibilityLabel(translate("topbar.renameMeeting", [:]))
                .help(translate("topbar.renameMeeting", [:]))
            }
        } else {
            Text(translate("topbar.startConversation", [:]))
                .font(currentTitleFont)
                .tracking(-0.504)
                .foregroundStyle(ArcoNativeColors.inkStrong)
        }
    }

    private func meetingDetails(_ summary: MeetingSummary, width: CGFloat) -> some View {
        let detail = meetingDetail?.summary.id == summary.id ? meetingDetail : nil
        let speakers = (detail?.lines.map(\.speaker).filter { !$0.isEmpty } ?? []).reduce(into: [String]()) { result, speaker in
            if !result.contains(speaker) { result.append(speaker) }
        }
        let remote = speakers.filter { $0.lowercased(with: .current).hasPrefix("remote") }
        let room = speakers.filter { $0.lowercased(with: .current).hasPrefix("in room") }
        let utterances = detail?.lines.count ?? summary.utteranceCount
        var rows = [
            TopBarDetailRow(key: "topbar.duration", value: durationLabel(summary.durationLabel), accessibilityLabel: nil),
            TopBarDetailRow(
                key: "topbar.transcript",
                value: "\(translate(utterances == 1 ? "topbar.utteranceCountOne" : "topbar.utteranceCount", ["count": "\(utterances)"])) · \(translate(speakers.count == 1 ? "topbar.speakerCountOne" : "topbar.speakerCount", ["count": "\(speakers.count)"]))",
                accessibilityLabel: nil
            ),
            TopBarDetailRow(
                key: "topbar.storage",
                value: (summary.path as NSString).abbreviatingWithTildeInPath,
                accessibilityLabel: summary.path,
                copyValue: summary.path
            )
        ]
        if let provider = transcriptionProvider {
            rows.append(TopBarDetailRow(key: "topbar.transcription", value: provider, accessibilityLabel: nil))
        }
        rows.append(TopBarDetailRow(
            key: "topbar.system",
            value: speakerList(remote),
            accessibilityLabel: translate("topbar.systemSpeakers", ["speakers": speakerList(remote)])
        ))
        rows.append(TopBarDetailRow(
            key: "topbar.room",
            value: speakerList(room),
            accessibilityLabel: translate("topbar.roomSpeakers", ["speakers": speakerList(room)])
        ))

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index == 4 {
                    ArcoNativeColors.lineThin
                        .frame(height: 1)
                        .padding(.top, 5)
                }
                detailRow(row.key, value: row.value, emphasizedTop: index == 4, copyValue: row.copyValue)
                    .modifier(TopBarAccessibilityLabel(label: row.accessibilityLabel))
            }
            Text(translate("topbar.locationLabels", [:]))
                .font(ArcoTypography.tiny)
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.leading, 96)
                .padding(.top, 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: width)
        .background(ArcoNativeColors.surfacePopover)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ArcoNativeColors.surfaceInnerHighlight)
                .frame(height: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(0.03), radius: 1, y: 2)
        .shadow(color: Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(0.05), radius: 4, y: 4)
        .shadow(color: Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(0.10), radius: 10, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("topbar.meetingDetails", [:]))
    }

    private func detailsOpen(for meeting: MeetingSummary) -> Bool {
        viewModel.detailsMeetingID == meeting.id
    }

    private func updateDetailsInteractionMonitor(open: Bool) {
        guard open else {
            detailsInteractionMonitor.deactivate()
            return
        }
        detailsInteractionMonitor.activate(
            onOutsideClick: { viewModel.detailsMeetingID = nil },
            onEscape: {
                viewModel.detailsMeetingID = nil
                detailsFocused = true
            }
        )
    }

    private func updateTitleInteractionMonitor(for meeting: MeetingSummary) {
        guard viewModel.isEditing(meeting) else {
            titleInteractionMonitor.deactivate()
            return
        }
        titleInteractionMonitor.activate(
            onOutsideClick: { commitEditingTitle(for: meeting) },
            onWindowResign: { commitEditingTitle(for: meeting) }
        )
    }

    private func commitEditingTitle(for meeting: MeetingSummary) {
        guard viewModel.isEditing(meeting), !titleCommitInProgress else { return }
        titleCommitInProgress = true
        Task {
            let saved = await viewModel.commitTitle(for: meeting)
            titleCommitInProgress = false
            titleFocused = !saved
            titleTriggerFocused = saved
        }
    }

    private func detailRow(_ key: String, value: String, emphasizedTop: Bool = false, copyValue: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(translate(key, [:]))
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                    pathCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        pathCopied = false
                    }
                } label: {
                    ArcoLucideIcon(pathCopied ? .check : .copy, size: 13)
                        .foregroundStyle(pathCopied ? ArcoNativeColors.brand : ArcoNativeColors.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(translate(pathCopied ? "topbar.pathCopied" : "topbar.copyPath", [:]))
                .help(translate(pathCopied ? "topbar.pathCopied" : "topbar.copyPath", [:]))
            }
        }
        .padding(.top, emphasizedTop ? 10 : 5)
        .padding(.bottom, 5)
    }

    private var recording: Bool {
        capture.phase == .recording && meeting?.id == capture.activeMeetingId
    }

    private var displayTitle: String {
        let trimmed = meeting?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? translate("common.untitledMeeting", [:]) : trimmed
    }

    private var currentTitleFont: Font {
        ArcoTypography.sans(28, weight: .semibold)
    }

    private var transcriptionProvider: String? {
        switch capture.transcription?.asr.provider {
        case .deepgram: "Deepgram"
        case .elevenlabs: "ElevenLabs"
        case .local: translate("common.onThisMac", [:])
        case .doubao, nil: nil
        }
    }

    private func durationLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.range(of: #"^(\d+)\s*(?:m|min)$"#, options: [.regularExpression, .caseInsensitive]) else { return value }
        let number = trimmed[match].prefix { $0.isNumber }
        return translate("history.durationMinutes", ["count": String(number)])
    }

    private func speakerList(_ speakers: [String]) -> String {
        guard !speakers.isEmpty else { return translate("common.waiting", [:]) }
        return speakers.map(localizedSpeaker).joined(separator: ", ")
    }

    private func localizedSpeaker(_ speaker: String) -> String {
        let number = speaker.firstMatch(of: /\d+/).map { String($0.output) } ?? "1"
        if speaker.lowercased(with: .current).hasPrefix("remote") {
            return translate("transcript.remoteSpeaker", ["number": number])
        }
        if speaker.lowercased(with: .current).hasPrefix("in room") {
            return translate("transcript.roomSpeaker", ["number": number])
        }
        return speaker
    }
}

private struct TopBarViewportWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> TopBarWindowWidthView {
        let view = TopBarWindowWidthView(frame: .zero)
        view.onWidthChange = updateWidth
        return view
    }

    func updateNSView(_ nsView: TopBarWindowWidthView, context: Context) {
        nsView.onWidthChange = updateWidth
        nsView.publishWidth()
    }

    private func updateWidth(_ nextWidth: CGFloat) {
        guard nextWidth > 0, width != nextWidth else { return }
        width = nextWidth
    }
}

private final class TopBarWindowWidthView: NSView {
    var onWidthChange: (CGFloat) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResizeNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
        }
        publishWidth()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        publishWidth()
    }

    func publishWidth() {
        guard let width = window?.contentView?.bounds.width, width > 0 else { return }
        onWidthChange(width)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private struct TopBarWidthPreferenceKey: PreferenceKey {
    static let defaultValue = TopBarDetailsLayout.maximumWidth + TopBarDetailsLayout.viewportMargin
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
private final class TopBarOutsideInteractionMonitor: NSObject, ObservableObject {
    private let regions = NSHashTable<NSView>.weakObjects()
    private var eventMonitor: Any?
    private var onOutsideClick: (() -> Void)?
    private var onEscape: (() -> Void)?
    private var onWindowResign: (() -> Void)?
    private var observingWindowResign = false

    func register(_ view: NSView) {
        regions.add(view)
    }

    func unregister(_ view: NSView) {
        regions.remove(view)
    }

    func activate(
        onOutsideClick: @escaping () -> Void,
        onEscape: (() -> Void)? = nil,
        onWindowResign: (() -> Void)? = nil
    ) {
        self.onOutsideClick = onOutsideClick
        self.onEscape = onEscape
        self.onWindowResign = onWindowResign
        if onWindowResign != nil, !observingWindowResign {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
            observingWindowResign = true
        } else if onWindowResign == nil, observingWindowResign {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
            observingWindowResign = false
        }
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            var result: NSEvent?
            MainActor.assumeIsolated {
                result = self?.handle(event) ?? event
            }
            return result
        }
    }

    func deactivate() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        onOutsideClick = nil
        onEscape = nil
        onWindowResign = nil
        if observingWindowResign {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
            observingWindowResign = false
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let belongsToMonitoredWindow = regions.allObjects.contains { $0.window === window }
        if belongsToMonitoredWindow { onWindowResign?() }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return event
        }
        guard event.type == .leftMouseDown
            || event.type == .rightMouseDown
            || event.type == .otherMouseDown
        else { return event }

        let clickedInside = regions.allObjects.contains { region in
            guard let window = region.window, event.window === window else { return false }
            return region.bounds.contains(region.convert(event.locationInWindow, from: nil))
        }
        if !clickedInside { onOutsideClick?() }
        return event
    }

}

private final class TopBarPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TopBarInteractionRegion: NSViewRepresentable {
    @ObservedObject var monitor: TopBarOutsideInteractionMonitor

    final class Coordinator {
        let monitor: TopBarOutsideInteractionMonitor
        init(monitor: TopBarOutsideInteractionMonitor) { self.monitor = monitor }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(monitor: monitor)
    }

    func makeNSView(context: Context) -> NSView {
        let view = TopBarPassthroughView(frame: .zero)
        context.coordinator.monitor.register(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.monitor.register(nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.monitor.unregister(nsView)
    }
}

private struct TopBarDetailRow {
    let key: String
    let value: String
    let accessibilityLabel: String?
    var copyValue: String? = nil
}

private struct TopBarAccessibilityLabel: ViewModifier {
    let label: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
        }
    }
}
