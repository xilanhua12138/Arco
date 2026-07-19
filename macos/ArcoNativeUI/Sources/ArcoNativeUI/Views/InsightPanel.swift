import AppKit
import SwiftUI

public enum InsightContextScope: String, Sendable {
    case transcript
    case workspace
}

public enum InsightPanelLayout: Sendable {
    case main
    case agentOverlay
}

@_spi(Testing)
public enum InsightAgentWorkPresentation {
    public static func durationLabel(milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

@_spi(Testing)
public enum InsightSourceLayout {
    /// SwiftUI's macOS TextEditor keeps AppKit's default line-fragment padding.
    /// The separately rendered placeholder must start at the same x-coordinate.
    public static let textContainerInset: CGFloat = 5

    public static func composerHeight(for layout: InsightPanelLayout) -> CGFloat {
        switch layout {
        case .main: 42
        case .agentOverlay: 40
        }
    }
}

public struct InsightAskRequest: Sendable {
    public var provider: ProviderID
    public var usedFallback: Bool
    public var question: String
    public var agentPrompt: String?
    public var meetingID: String
    public var contextScope: InsightContextScope
    public var workspace: String?

    public init(
        provider: ProviderID,
        usedFallback: Bool,
        question: String,
        agentPrompt: String?,
        meetingID: String,
        contextScope: InsightContextScope,
        workspace: String?
    ) {
        self.provider = provider
        self.usedFallback = usedFallback
        self.question = question
        self.agentPrompt = agentPrompt
        self.meetingID = meetingID
        self.contextScope = contextScope
        self.workspace = workspace
    }
}

public struct InsightPanelView: View {
    public var meeting: MeetingDetail?
    public var replies: [AgentTurn]
    public var runtimes: [RuntimeStatus]
    public var provider: ProviderID?
    public var primaryProvider: ProviderID?
    public var isFailover: Bool
    public var running: Bool
    public var workspace: String?
    public var live: Bool
    public var showHeader: Bool
    public var layout: InsightPanelLayout
    public var streamingTurn: AgentStreamingTurn?
    public var translate: ArcoTranslate

    public var onAsk: (InsightAskRequest) async throws -> Bool
    public var onToggleSaved: (String, String, Bool) async -> Bool
    public var onChooseWorkspace: () async -> String?
    public var onCopy: (String) async throws -> Void
    public var onClose: (() -> Void)?
    public var onConnectAgent: (() -> Void)?

    private var externalQuestion: Binding<String>?
    @State private var localQuestion: String
    @State private var scope: InsightContextScope = .transcript
    @State private var copiedReplyIndex: Int?
    @State private var requestError = false
    @State private var contextMenuOpen = false
    @State private var openContextTurnID: String?
    @State private var savingTurnID: String?
    @State private var pendingQuestion: String?
    @State private var measuredWidth: CGFloat = .infinity
    @State private var closeHovering = false
    @State private var contextButtonHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        meeting: MeetingDetail?,
        replies: [AgentTurn],
        runtimes: [RuntimeStatus],
        provider: ProviderID?,
        primaryProvider: ProviderID?,
        isFailover: Bool,
        running: Bool,
        question: Binding<String>? = nil,
        workspace: String? = nil,
        live: Bool = false,
        showHeader: Bool = false,
        layout: InsightPanelLayout = .main,
        streamingTurn: AgentStreamingTurn? = nil,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onAsk: @escaping (InsightAskRequest) async throws -> Bool,
        onToggleSaved: @escaping (String, String, Bool) async -> Bool,
        onChooseWorkspace: @escaping () async -> String? = { nil },
        onCopy: @escaping (String) async throws -> Void,
        onClose: (() -> Void)? = nil,
        onConnectAgent: (() -> Void)? = nil
    ) {
        self.meeting = meeting
        self.replies = replies
        self.runtimes = runtimes
        self.provider = provider
        self.primaryProvider = primaryProvider
        self.isFailover = isFailover
        self.running = running
        self.externalQuestion = question
        self._localQuestion = State(initialValue: question?.wrappedValue ?? "")
        self.workspace = workspace
        self.live = live
        self.showHeader = showHeader
        self.layout = layout
        self.streamingTurn = streamingTurn
        self.translate = translate
        self.onAsk = onAsk
        self.onToggleSaved = onToggleSaved
        self.onChooseWorkspace = onChooseWorkspace
        self.onCopy = onCopy
        self.onClose = onClose
        self.onConnectAgent = onConnectAgent
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showHeader { header }

            GeometryReader { viewport in
                ScrollView {
                    bodyContent
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(1, viewport.size.height - bodyVerticalInsets),
                            alignment: .topLeading
                        )
                        .padding(.horizontal, bodyHorizontalInset)
                        .padding(.top, bodyTopInset)
                        .padding(.bottom, bodyBottomInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if provider != nil, meeting != nil {
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            layout == .agentOverlay
                ? Color.white.opacity(0.32)
                : ArcoNativeColors.surfaceDocument
        )
        .clipped()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: InsightWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(InsightWidthPreferenceKey.self) { measuredWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("agent.askArco", [:]))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(translate("agent.askArco", [:]))
                .font(ArcoTypography.surfaceTitle)
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .tracking(-0.16)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if live {
                HStack(spacing: 5) {
                    Circle()
                        .fill(ArcoNativeColors.record)
                        .frame(width: 6, height: 6)
                    Text(translate("agent.live", [:]))
                        .font(ArcoTypography.sans(11, weight: .medium))
                }
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.top, 2)
            }
            if let onClose {
                Button(action: onClose) {
                    ArcoLucideIcon(.x, size: 17)
                        .frame(width: 30, height: 30)
                        .background(
                            closeHovering ? ArcoNativeColors.surfaceHover : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.94))
                .foregroundStyle(closeHovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                .onHover { closeHovering = $0 }
                .accessibilityLabel(translate("agent.close", [:]))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if provider == nil {
            dockState(
                titleKey: "agent.connectAgentTitle",
                helpKey: "agent.connectFirst",
                actionKey: onConnectAgent == nil ? nil : "agent.setUpAgent",
                action: onConnectAgent
            )
        } else if meeting == nil {
            dockState(
                titleKey: "agent.waitingForMeeting",
                helpKey: "agent.startListeningHelp",
                actionKey: nil,
                action: nil
            )
        } else {
            agentConversation
        }
    }

    private func dockState(
        titleKey: String,
        helpKey: String,
        actionKey: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 0) {
            Text(translate(titleKey, [:]))
                .font(ArcoTypography.sans(17, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineSpacing(3.6)
                .accessibilityAddTraits(.isHeader)
            Text(translate(helpKey, [:]))
                .font(ArcoTypography.sans(13))
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .lineSpacing(4.4)
                .padding(.top, 7)
            if let actionKey, let action {
                Button(action: action) {
                    Text(translate(actionKey, [:]))
                        .font(ArcoTypography.sans(12, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.actionInk)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(ArcoNativeColors.action)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle())
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: 260)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        .padding(.vertical, 32)
    }

    private var agentConversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            if runtime?.available != true {
                inlineNotice(
                    title: translate("agent.notFound", ["runtime": provider?.runtimeName ?? ""]),
                    message: translate("agent.notFoundHelp", [:]),
                    warning: true
                )
            }

            if isFailover {
                inlineNotice(
                    title: nil,
                    message: translate("agent.failover", [
                        "primary": primaryProvider?.displayName ?? "",
                        "provider": provider?.displayName ?? ""
                    ]),
                    warning: false
                )
                .padding(.bottom, 10)
            }

            if replies.isEmpty && pendingQuestion == nil {
                quickActions
            }

            ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                replyView(reply, index: index)
                    .padding(.top, index == 0 ? 0 : replySpacing)
            }

            if let pendingQuestion {
                VStack(alignment: .leading, spacing: 0) {
                    replyDividerIfNeeded
                    Text(pendingQuestion)
                        .font(ArcoTypography.sans(13, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .lineSpacing(2.4)
                        .padding(.bottom, 10)
                        .accessibilityAddTraits(.isHeader)
                    if let streaming = activeStreamingTurn {
                        AgentWorkDisclosure(
                            activities: streaming.toolActivities,
                            running: true,
                            startedAt: streaming.startedAt,
                            durationMs: nil,
                            emptyLabel: streamingStatus,
                            translate: translate
                        )
                        .padding(.bottom, 10)

                        if !streaming.answer.isEmpty {
                            MarkdownContentView(
                                streaming.answer,
                                compact: measuredWidth <= 340,
                                overlayParagraphs: layout == .agentOverlay
                            )
                        }
                    } else {
                        ThinkingIndicator(label: streamingStatus)
                    }
                }
                .padding(.top, replies.isEmpty ? 0 : replySpacing)
                .frame(
                    maxWidth: ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: 70),
                    alignment: .leading
                )
            }

            if running && pendingQuestion == nil {
                ThinkingIndicator(label: streamingStatus)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runtime: RuntimeStatus? {
        guard let provider else { return nil }
        return runtimes.first { $0.provider == provider }
    }

    private var activeStreamingTurn: AgentStreamingTurn? {
        guard streamingTurn?.meetingId == meeting?.summary.id else { return nil }
        return streamingTurn
    }

    private var streamingStatus: String {
        switch activeStreamingTurn?.phase {
        case "starting": translate("agent.stream.starting", [:])
        case "using-tools": translate("agent.stream.usingTools", [:])
        case "finalizing": translate("agent.stream.finalizing", [:])
        default: translate("agent.thinking", [:])
        }
    }

    private func inlineNotice(title: String?, message: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ArcoLucideIcon(.circleAlert, size: 16)
                .foregroundStyle(warning ? ArcoNativeColors.warning : ArcoNativeColors.ink)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(ArcoTypography.sans(11, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                }
                Text(message)
                    .font(ArcoTypography.small)
                    .foregroundStyle(warning ? ArcoNativeColors.warning : ArcoNativeColors.ink)
                    .lineSpacing(2.8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ArcoNativeColors.surfaceSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var quickActions: some View {
        VStack(spacing: 0) {
            ForEach(Array(quickPrompts.enumerated()), id: \.offset) { index, prompt in
                Button {
                    Task { @MainActor in await submit(displayQuestion: prompt.label, agentPrompt: prompt.prompt) }
                } label: {
                    HStack(spacing: 12) {
                        Text(prompt.label)
                            .font(ArcoTypography.sans(13, weight: .medium))
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                        Spacer()
                        ArcoLucideIcon(.arrowUp, size: 14)
                    }
                    .padding(.horizontal, layout == .agentOverlay ? 12 : 14)
                    .padding(.vertical, layout == .agentOverlay ? 11 : 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.995))
                .disabled(actionsDisabled)
                .opacity(actionsDisabled ? 0.4 : 1)
                .modifier(InsightHoverBackground(cornerRadius: 0))
                .accessibilityLabel(prompt.label)

                if index < quickPrompts.count - 1 {
                    ArcoNativeColors.lineThin.frame(height: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ArcoNativeColors.lineThin, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("agent.suggestedActions", [:]))
    }

    private var quickPrompts: [(label: String, prompt: String)] {
        [
            (translate("agent.quick.answer.label", [:]), translate("agent.quick.answer.prompt", [:])),
            (translate("agent.quick.unresolved.label", [:]), translate("agent.quick.unresolved.prompt", [:])),
            (translate("agent.quick.challenge.label", [:]), translate("agent.quick.challenge.prompt", [:]))
        ]
    }

    private var actionsDisabled: Bool {
        running || pendingQuestion != nil || runtime?.available != true || workspaceMissing
    }

    private var usableWorkspace: String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        return workspace
    }

    private var workspaceMissing: Bool { scope == .workspace && usableWorkspace == nil }

    private var bodyHorizontalInset: CGFloat { layout == .agentOverlay ? 16 : 24 }
    private var bodyTopInset: CGFloat { layout == .agentOverlay ? 14 : 18 }
    private var bodyBottomInset: CGFloat { layout == .agentOverlay ? 18 : 24 }
    private var bodyVerticalInsets: CGFloat { bodyTopInset + bodyBottomInset }
    private var replySpacing: CGFloat { layout == .agentOverlay ? 16 : 22 }

    @ViewBuilder
    private func replyView(_ reply: AgentTurn, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if index > 0 { replyDividerIfNeeded }

            if reply.usedFallback {
                Text(translate("agent.fallback", ["provider": reply.provider.displayName]))
                    .font(ArcoTypography.sans(9, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.warning)
                    .tracking(0.45)
                    .textCase(.uppercase)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ArcoNativeColors.warning.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(.bottom, 6)
            }

            Text(reply.question)
                .font(ArcoTypography.sans(13, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineSpacing(2.4)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)

            if reply.workDurationMs != nil || !reply.toolActivities.isEmpty {
                AgentWorkDisclosure(
                    activities: reply.toolActivities,
                    running: false,
                    startedAt: nil,
                    durationMs: reply.workDurationMs,
                    emptyLabel: nil,
                    translate: translate
                )
                .padding(.bottom, 10)
            }

            MarkdownContentView(
                reply.answer,
                compact: measuredWidth <= 340,
                overlayParagraphs: layout == .agentOverlay
            )

            HStack(spacing: 1) {
                if !reply.sources.isEmpty {
                    replyAction(
                        label: "\(translate("agent.contextUsed", [:])) · \(reply.sources.count)",
                        icon: .chevronRight,
                        selected: openContextTurnID == reply.id,
                        rotateIcon: openContextTurnID == reply.id
                    ) {
                        if reduceMotion {
                            openContextTurnID = openContextTurnID == reply.id ? nil : reply.id
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) {
                                openContextTurnID = openContextTurnID == reply.id ? nil : reply.id
                            }
                        }
                    }
                }

                replyAction(
                    label: savingTurnID == reply.id
                        ? translate("common.saving", [:])
                        : reply.savedAsNote
                            ? translate("agent.savedNote", [:])
                            : translate("agent.saveAsNote", [:]),
                    icon: reply.savedAsNote ? .check : .bookmark,
                    disabled: savingTurnID == reply.id
                ) {
                    savingTurnID = reply.id
                    Task { @MainActor in
                        _ = await onToggleSaved(reply.meetingId, reply.id, !reply.savedAsNote)
                        savingTurnID = nil
                    }
                }

                replyAction(
                    label: copiedReplyIndex == index
                        ? translate("agent.copied", [:])
                        : translate("agent.copy", [:]),
                    icon: copiedReplyIndex == index ? .check : .copy,
                    hideLabel: measuredWidth <= 340
                ) {
                    Task { @MainActor in
                        do {
                            try await onCopy(reply.answer)
                            copiedReplyIndex = index
                            try? await Task.sleep(for: .milliseconds(1_500))
                            copiedReplyIndex = nil
                        } catch {
                            // Clipboard failure intentionally leaves the action in its idle state.
                        }
                    }
                }
            }
            .padding(.top, 2)

            if openContextTurnID == reply.id {
                VStack(spacing: 0) {
                    ForEach(Array(reply.sources.enumerated()), id: \.element.id) { sourceIndex, source in
                        HStack(spacing: 6) {
                            Text(String(format: "%02d", sourceIndex + 1))
                                .font(ArcoTypography.mono(9))
                                .foregroundStyle(ArcoNativeColors.inkMuted)
                            ArcoLucideIcon(sourceIcon(source.kind), size: 13)
                            Text(source.label)
                                .font(ArcoTypography.small)
                                .lineLimit(2)
                        }
                        .foregroundStyle(ArcoNativeColors.ink)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { ArcoNativeColors.lineThin.frame(height: 1) }
                    }
                }
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(translate("agent.contextUsedAria", [:]))
            }
        }
        .frame(
            maxWidth: ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: 70),
            alignment: .leading
        )
    }

    private var replyDividerIfNeeded: some View {
        ArcoNativeColors.lineThin
            .frame(height: 1)
            .padding(.bottom, replySpacing)
    }

    private func sourceIcon(_ kind: String) -> ArcoLucideSymbol {
        switch kind {
        case "transcript": .bookOpenText
        case "workspace": .fileSearch
        default: .link2
        }
    }

    private func replyAction(
        label: String,
        icon: ArcoLucideSymbol,
        selected: Bool = false,
        rotateIcon: Bool = false,
        disabled: Bool = false,
        hideLabel: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ArcoLucideIcon(icon, size: 13)
                    .rotationEffect(.degrees(rotateIcon ? 90 : 0))
                if !hideLabel {
                    Text(label).font(ArcoTypography.small)
                }
            }
            .foregroundStyle(selected ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .modifier(InsightHoverBackground(cornerRadius: 6, active: selected))
        .accessibilityLabel(label)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                contextChip(
                    label: translate("agent.scope.transcript", [:]),
                    icon: .bookOpenText,
                    fixed: true,
                    action: nil
                )
                if scope == .workspace, let workspace = usableWorkspace {
                    contextChip(
                        label: workspaceName(workspace),
                        icon: .folderOpen,
                        fixed: false,
                        action: {
                            Task { @MainActor in _ = await onChooseWorkspace() }
                        }
                    )
                    .accessibilityLabel(translate("agent.changeWorkspace", [:]))
                    .help(workspace)
                }
            }
            .padding(.bottom, 9)
            .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
            .padding(.top, -4)
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(translate("agent.referenceContext", [:]))

            ZStack(alignment: .topLeading) {
                if questionText.isEmpty {
                    Text(translate("agent.placeholder", [:]))
                        .font(ArcoTypography.body)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                        .padding(.top, 1)
                        .padding(.leading, InsightSourceLayout.textContainerInset)
                        .allowsHitTesting(false)
                }
                TextEditor(text: questionBinding)
                    .font(ArcoTypography.body)
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                    .lineSpacing(4.2)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .contentMargins(0, for: .scrollContent)
                    .frame(height: InsightSourceLayout.composerHeight(for: layout))
                    .padding(0)
                    .accessibilityLabel(translate("agent.questionAria", [:]))
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return, !press.modifiers.contains(.shift) else { return .ignored }
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                           editor.hasMarkedText()
                        {
                            return .ignored
                        }
                        Task { @MainActor in await submit() }
                        return .handled
                    }
            }

            if requestError {
                Text(translate("agent.requestError", [:]))
                    .font(ArcoTypography.tiny)
                    .foregroundStyle(ArcoNativeColors.record)
                    .padding(.top, 8)
                    .accessibilityLabel(translate("agent.requestError", [:]))
            }

            HStack {
                contextMenu
                Spacer()
                Button {
                    Task { @MainActor in await submit() }
                } label: {
                    ArcoLucideIcon(.arrowUp, size: 16)
                        .foregroundStyle(sendButtonForeground)
                        .frame(width: 32, height: 32)
                        .background(sendButtonBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.94))
                .disabled(sendDisabled)
                .accessibilityLabel(translate("agent.send", [:]))
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, layout == .agentOverlay ? 11 : 24)
        .padding(.vertical, layout == .agentOverlay ? 11 : 0)
        .padding(.top, layout == .agentOverlay ? 0 : 12)
        .padding(.bottom, layout == .agentOverlay ? 0 : 16)
        .background(layout == .agentOverlay ? Color.clear : ArcoNativeColors.surfaceDocument)
        .overlay(alignment: .top) { ArcoNativeColors.lineThin.frame(height: 1) }
        .padding(.horizontal, layout == .agentOverlay ? 16 : 0)
        .padding(.bottom, layout == .agentOverlay ? 16 : 0)
    }

    private func contextChip(
        label: String,
        icon: ArcoLucideSymbol,
        fixed: Bool,
        action: (() -> Void)?
    ) -> some View {
        Group {
            if let action {
                Button(action: action) { contextChipLabel(label: label, icon: icon, fixed: fixed) }
                    .buttonStyle(ArcoPressFeedbackButtonStyle())
            } else {
                contextChipLabel(label: label, icon: icon, fixed: fixed)
            }
        }
    }

    private func contextChipLabel(label: String, icon: ArcoLucideSymbol, fixed: Bool) -> some View {
        HStack(spacing: 5) {
            ArcoLucideIcon(icon, size: 11)
            Text(label)
                .font(ArcoTypography.tiny)
                .lineLimit(1)
        }
        .foregroundStyle(fixed ? ArcoNativeColors.inkMuted : ArcoNativeColors.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: 150)
        .background(ArcoNativeColors.surfaceSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var contextMenu: some View {
        ZStack(alignment: .bottomLeading) {
            Button {
                contextMenuOpen.toggle()
            } label: {
                ArcoLucideIcon(.plus, size: 16)
                    .foregroundStyle(
                        contextMenuOpen || contextButtonHovering
                            ? ArcoNativeColors.inkStrong
                            : ArcoNativeColors.ink
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        contextMenuOpen || contextButtonHovering ? ArcoNativeColors.surfaceHover : .clear,
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.94))
            .onHover { contextButtonHovering = $0 }
            .accessibilityLabel(translate("agent.addContext", [:]))
            .help(translate("agent.contextMenu", [:]))

            if contextMenuOpen {
                composerContextMenu
                    .offset(y: -35)
                    .zIndex(4)
            }
        }
        .frame(width: 28, height: 28, alignment: .bottomLeading)
        .zIndex(4)
    }

    private var composerContextMenu: some View {
        VStack(spacing: 0) {
            if let workspace = usableWorkspace, scope == .transcript {
                InsightContextMenuItem(
                    icon: .folderOpen,
                    label: translate("agent.useWorkspace", ["workspace": workspaceName(workspace)])
                ) {
                    scope = .workspace
                    contextMenuOpen = false
                }
            }
            if scope == .workspace {
                InsightContextMenuItem(
                    icon: .bookOpenText,
                    label: translate("agent.useTranscriptOnly", [:])
                ) {
                    scope = .transcript
                    contextMenuOpen = false
                }
            }
            InsightContextMenuItem(
                icon: .folderOpen,
                label: usableWorkspace == nil
                    ? translate("agent.chooseWorkspace", [:])
                    : translate("agent.chooseAnotherWorkspace", [:])
            ) {
                Task { @MainActor in
                    if await onChooseWorkspace() != nil { scope = .workspace }
                    contextMenuOpen = false
                }
            }
        }
        .padding(4)
        .frame(width: 196)
        .background(ArcoNativeColors.surfacePopover)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ArcoNativeColors.line, lineWidth: 1)
        }
        .shadow(color: Color(red: 18 / 255, green: 24 / 255, blue: 34 / 255).opacity(0.12), radius: 6, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("agent.contextMenu", [:]))
    }

    private var questionBinding: Binding<String> {
        Binding(
            get: { externalQuestion?.wrappedValue ?? localQuestion },
            set: { value in
                if let externalQuestion { externalQuestion.wrappedValue = value }
                else { localQuestion = value }
            }
        )
    }

    private var questionText: String { externalQuestion?.wrappedValue ?? localQuestion }

    private var sendDisabled: Bool {
        questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || running
            || pendingQuestion != nil
            || meeting == nil
            || runtime?.available != true
            || workspaceMissing
    }

    private var sendButtonForeground: Color {
        sendDisabled ? ArcoNativeColors.inkMuted : ArcoNativeColors.actionInk
    }

    private var sendButtonBackground: Color {
        sendDisabled ? ArcoNativeColors.surfaceSubtle : ArcoNativeColors.action
    }

    @MainActor
    private func submit(displayQuestion: String? = nil, agentPrompt: String? = nil) async {
        guard let meeting, let provider else { return }
        let visibleQuestion = (displayQuestion ?? questionText).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = agentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleQuestion.isEmpty,
              !running,
              pendingQuestion == nil,
              runtime?.available == true,
              !workspaceMissing
        else { return }

        requestError = false
        pendingQuestion = visibleQuestion
        questionBinding.wrappedValue = ""

        let request = InsightAskRequest(
            provider: provider,
            usedFallback: isFailover,
            question: visibleQuestion,
            agentPrompt: normalizedPrompt?.nilIfEmpty,
            meetingID: meeting.summary.id,
            contextScope: scope,
            workspace: scope == .workspace ? workspace : nil
        )

        do {
            let succeeded = try await onAsk(request)
            if !succeeded {
                questionBinding.wrappedValue = visibleQuestion
                requestError = true
            }
            pendingQuestion = nil
        } catch {
            questionBinding.wrappedValue = visibleQuestion
            requestError = true
            pendingQuestion = nil
        }
    }

    private func workspaceName(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? path
    }
}

public typealias InsightPanel = InsightPanelView

private struct InsightWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ThinkingIndicator: View {
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

private struct AgentWorkDisclosure: View {
    let activities: [AgentToolActivity]
    let running: Bool
    let startedAt: Date?
    let durationMs: UInt64?
    let emptyLabel: String?
    let translate: ArcoTranslate

    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        activities: [AgentToolActivity],
        running: Bool,
        startedAt: Date?,
        durationMs: UInt64?,
        emptyLabel: String?,
        translate: @escaping ArcoTranslate
    ) {
        self.activities = activities
        self.running = running
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.emptyLabel = emptyLabel
        self.translate = translate
        self._expanded = State(initialValue: running)
    }

    private var canExpand: Bool { !activities.isEmpty || (running && emptyLabel != nil) }
    private var hasRunningTools: Bool { activities.contains { $0.status == "running" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    disclosureButton(label: workLabel(at: timeline.date))
                }
            } else {
                disclosureButton(label: workLabel(at: Date()))
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if activities.isEmpty, let emptyLabel {
                        ThinkingIndicator(label: emptyLabel)
                            .padding(.vertical, 4)
                    }
                    ForEach(activities) { activity in
                        AgentToolActivityRow(activity: activity, translate: translate)
                    }
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ArcoNativeColors.lineThin.frame(height: 1)
        }
        .onChange(of: hasRunningTools) { wasRunning, isRunning in
            if isRunning {
                setExpanded(true)
            } else if wasRunning {
                setExpanded(false)
            }
        }
        .onChange(of: running) { wasRunning, isRunning in
            if wasRunning && !isRunning { setExpanded(false) }
        }
    }

    private func disclosureButton(label: String) -> some View {
        Button {
            guard canExpand else { return }
            toggleExpanded()
        } label: {
            HStack(spacing: 7) {
                Text(label)
                    .font(ArcoTypography.sans(12, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .lineLimit(1)
                if canExpand {
                    ArcoLucideIcon(.chevronRight, size: 13, strokeWidth: 1.8)
                        .foregroundStyle(ArcoNativeColors.inkFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Spacer(minLength: 0)
                if activities.contains(where: { $0.status == "failed" }) {
                    ArcoLucideIcon(.circleAlert, size: 13)
                        .foregroundStyle(ArcoNativeColors.warning)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.995))
        .disabled(!canExpand)
        .accessibilityLabel(label)
        .accessibilityValue(expanded ? translate("agent.work.expanded", [:]) : translate("agent.work.collapsed", [:]))
    }

    private func workLabel(at now: Date) -> String {
        if running {
            let elapsed = max(0, now.timeIntervalSince(startedAt ?? now))
            let milliseconds = UInt64(min(elapsed * 1_000, Double(UInt64.max)))
            guard milliseconds >= 1_000 else { return translate("agent.work.processing", [:]) }
            return translate("agent.work.processingFor", [
                "time": InsightAgentWorkPresentation.durationLabel(milliseconds: milliseconds)
            ])
        }
        return translate("agent.work.completed", [
            "time": InsightAgentWorkPresentation.durationLabel(milliseconds: durationMs ?? 0)
        ])
    }

    private func toggleExpanded() { setExpanded(!expanded) }

    private func setExpanded(_ value: Bool) {
        if reduceMotion {
            expanded = value
        } else {
            withAnimation(.easeOut(duration: 0.18)) { expanded = value }
        }
    }
}

private struct AgentToolActivityRow: View {
    let activity: AgentToolActivity
    let translate: ArcoTranslate

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasDetails: Bool { activity.detail != nil || activity.output != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetails else { return }
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ArcoLucideIcon(kindIcon, size: 13, strokeWidth: 1.8)
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                        Text(previewLabel)
                            .font(activity.kind == "command" ? ArcoTypography.mono(11) : ArcoTypography.small)
                            .foregroundStyle(ArcoNativeColors.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(ArcoNativeColors.surfaceSubtle)
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(ArcoNativeColors.lineThin, lineWidth: 1) }

                    statusView
                    Spacer(minLength: 0)
                    if hasDetails {
                        ArcoLucideIcon(.chevronRight, size: 12, strokeWidth: 1.8)
                            .foregroundStyle(ArcoNativeColors.inkFaint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.995))
            .disabled(!hasDetails)
            .accessibilityLabel("\(activity.name), \(statusLabel)")
            .accessibilityValue(expanded ? translate("agent.work.expanded", [:]) : translate("agent.work.collapsed", [:]))

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    if let detail = activity.detail {
                        toolDetail(title: translate("agent.tool.input", [:]), text: detail)
                    }
                    if let output = activity.output {
                        toolDetail(title: translate("agent.tool.output", [:]), text: output)
                    }
                }
                .padding(.top, 7)
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        HStack(spacing: 5) {
            switch activity.status {
            case "running":
                ArcoSpinningRefreshIcon(active: true, size: 11)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            case "failed":
                ArcoLucideIcon(.circleAlert, size: 12)
                    .foregroundStyle(ArcoNativeColors.warning)
            default:
                ArcoLucideIcon(.check, size: 12)
                    .foregroundStyle(ArcoNativeColors.success)
            }
            Text(statusLabel)
                .font(ArcoTypography.small)
                .foregroundStyle(activity.status == "failed" ? ArcoNativeColors.warning : ArcoNativeColors.inkMuted)
                .lineLimit(1)
        }
    }

    private var statusLabel: String {
        switch activity.status {
        case "running": translate("agent.tool.running", [:])
        case "failed": translate("agent.tool.failed", [:])
        default: translate("agent.tool.completed", [:])
        }
    }

    private var previewLabel: String {
        guard let detail = activity.detail else { return activity.name }
        if activity.kind == "command" { return detail.replacingOccurrences(of: "\n", with: " ") }
        guard detail.first == "{",
              let data = detail.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return activity.name }
        for key in ["file_path", "path", "query", "pattern"] {
            if let value = object[key] as? String, !value.isEmpty {
                return "\(activity.name) · \(value)"
            }
        }
        return activity.name
    }

    private var kindIcon: ArcoLucideSymbol {
        switch activity.kind {
        case "read": .bookOpenText
        case "search", "web": .fileSearch
        case "file", "command": .fileText
        default: .link2
        }
    }

    private func toolDetail(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ArcoTypography.sans(9, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkFaint)
                .tracking(0.35)
                .textCase(.uppercase)
            Text(text)
                .font(ArcoTypography.mono(10))
                .foregroundStyle(ArcoNativeColors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ArcoNativeColors.surfaceSubtle)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct InsightContextMenuItem: View {
    let icon: ArcoLucideSymbol
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ArcoLucideIcon(icon, size: 14)
                Text(label)
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovering ? ArcoNativeColors.surfaceHover : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.995))
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

private struct InsightHoverBackground: ViewModifier {
    let cornerRadius: CGFloat
    var active = false

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                active || hovering ? ArcoNativeColors.surfaceHover : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { hovering = $0 }
    }
}
