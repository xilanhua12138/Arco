import AppKit
import SwiftUI

public struct ArcoMainShellView: View {
    @StateObject private var controller: ArcoAppShellController
    @State private var liveReviewHovered = false
    @FocusState private var settingsTriggerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private let translate: ArcoTranslate

    @MainActor
    public init(
        controller: ArcoAppShellController,
        translate: @escaping ArcoTranslate
    ) {
        _controller = StateObject(wrappedValue: controller)
        self.translate = translate
    }

    @MainActor
    public init(
        store: ArcoStore,
        preferences: ArcoPreferences,
        translate: @escaping ArcoTranslate,
        environment: ArcoAppEnvironment = ArcoAppEnvironment()
    ) {
        self.init(
            controller: ArcoAppShellController(
                store: store,
                preferences: preferences,
                translate: translate,
                environment: environment
            ),
            translate: translate
        )
    }

    public var body: some View {
        rootContent
            .ignoresSafeArea(.container, edges: .all)
            .preferredColorScheme(.light)
            .modifier(ArcoAppStoreSynchronizationModifier(controller: controller))
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .onChange(of: controller.settingsFocusRestoreGeneration) { _, _ in
                settingsTriggerFocused = true
            }
    }

    @ViewBuilder private var rootContent: some View {
        Group {
            if controller.providerSetupOpen && !controller.editingProviders {
                onboarding
            } else {
                applicationShell
            }
        }
    }

    private var onboarding: some View {
        OnboardingView(
            viewModel: controller.onboardingViewModel(),
            shortcutViewModel: controller.shortcutViewModel,
            locale: localeBinding,
            shortcutTestCount: controller.shortcutTestCount,
            translate: translate
        )
    }

    private var applicationShell: some View {
        GeometryReader { geometry in
            applicationShell(viewportWidth: geometry.size.width)
        }
    }

    private func applicationShell(viewportWidth: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: ArcoLayoutMetrics.sidebarStageGap) {
                sidebar
                    .frame(width: ArcoLayoutMetrics.sidebarWidth)
                pageStage(viewportWidth: viewportWidth)
            }
            .padding(ArcoLayoutMetrics.windowInset)
            .background(ArcoNativeColors.surfaceStageBase)
            .clipShape(RoundedRectangle(cornerRadius: ArcoLayoutMetrics.pageCornerRadius, style: .continuous))

            mainWindowDragRegions

            if let message = controller.store.error ?? controller.store.storageError ?? controller.interfaceError {
                errorToast(message)
                    .padding(16)
                    .transition(
                        accessibilityReduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom))
                    )
            }

            if controller.settingsOpen {
                ArcoSettingsSheetView(
                    viewModel: controller.settingsViewModel(),
                    translate: translate
                )
                .transition(
                    accessibilityReduceMotion
                        ? .opacity
                        : .opacity.combined(
                            with: .scale(scale: 0.96, anchor: .bottomLeading)
                        )
                )
                .zIndex(4)
            }

            if controller.providerSetupOpen && controller.editingProviders {
                ProviderSetupView(
                    viewModel: controller.providerViewModel(),
                    shortcutViewModel: controller.shortcutViewModel,
                    locale: localeBinding,
                    translate: translate,
                    onCancel: controller.cancelProviderSetup
                )
                .transition(.opacity)
                .zIndex(5)
            }
        }
        .animation(accessibilityReduceMotion ? nil : ArcoMotion.sheet, value: controller.settingsOpen)
        .animation(accessibilityReduceMotion ? nil : ArcoMotion.state, value: controller.providerSetupOpen)
        .accessibilityElement(children: .contain)
    }

    private var mainWindowDragRegions: some View {
        HStack(alignment: .top, spacing: ArcoLayoutMetrics.sidebarStageGap) {
            ArcoWindowDragRegion()
                .frame(
                    width: ArcoLayoutMetrics.sidebarWidth,
                    height: ArcoLayoutMetrics.sidebarTitlebarClearance
                )
            ArcoWindowDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: ArcoLayoutMetrics.titlebarClearance)
        }
        .padding(ArcoLayoutMetrics.windowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(!controller.settingsOpen && !controller.providerSetupOpen)
        .zIndex(1)
        .accessibilityHidden(true)
    }

    private var sidebar: some View {
        let shape = RoundedRectangle(cornerRadius: ArcoLayoutMetrics.sidebarCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text("Arco")
                    .font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, ArcoLayoutMetrics.sidebarTitlebarClearance)
            .padding(.bottom, 14)

            VStack(spacing: 3) {
                navigationButton(.current, symbol: "dot.radiowaves.left.and.right", key: "nav.current")
                navigationButton(.history, symbol: "clock", key: "nav.history", selectedWhenReviewing: true)
                navigationButton(.notes, symbol: "note.text", key: "nav.notes")
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(translate("nav.main", [:]))

            Spacer(minLength: 18)
            captureCard
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)
            HStack {
                Spacer()
                sidebarSettingsButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .foregroundStyle(ArcoNativeGlassPalette.ink)
        .arcoLiquidGlass(in: shape)
    }

    private func navigationButton(
        _ route: AppRoute,
        symbol: String,
        key: String,
        selectedWhenReviewing: Bool = false
    ) -> some View {
        let selected = controller.page == route || (selectedWhenReviewing && controller.page == .review)
        return Button {
            controller.requestPage(route)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(translate(key, [:]))
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? ArcoNativeGlassPalette.ink : ArcoNativeGlassPalette.secondaryInk)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(SidebarNavigationButtonStyle(selected: selected))
        .accessibilityLabel(translate(route == .current ? "nav.openCurrent" : route == .history ? "nav.openHistory" : "nav.openNotes", [:]))
    }

    private var captureCard: some View {
        let capture = controller.store.capture
        let recording = capture.phase == .recording
        let stoppable = capture.phase == .starting || recording
        let busy = controller.store.loading
            || capture.phase == .stopping
        let showAction = controller.page != .current || stoppable
        let mode = captureMode
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: recording ? "waveform" : "water.waves")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(recording ? ArcoNativeGlassPalette.recording : ArcoNativeGlassPalette.secondaryInk)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(captureStatus)
                        .font(.system(size: 13, weight: .semibold))
                    Text(mode.label)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(ArcoNativeGlassPalette.secondaryInk)
                }
                Spacer(minLength: 0)
            }
            if showAction {
                sidebarCaptureButton(recording: stoppable, enabled: !busy)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ArcoNativeGlassPalette.ink.opacity(0.09), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("capture.audioLabel", ["mode": mode.label, "source": mode.source]))
    }

    @ViewBuilder private func sidebarCaptureButton(recording: Bool, enabled: Bool) -> some View {
        let tint = recording ? ArcoNativeGlassPalette.recording : ArcoNativeGlassPalette.action
        let button = Button {
            let resume = controller.page == .review ? controller.store.meeting?.summary.id : nil
            Task { await controller.toggleCapture(resumeMeetingID: resume) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: recording ? "stop.fill" : "waveform")
                    .font(.system(size: recording ? 12 : 15, weight: .medium))
                    .frame(
                        width: recording ? 12 : 15,
                        height: recording ? 12 : 15
                    )
                Text(captureActionLabel)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            .contentShape(Capsule())
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.985))
        .disabled(!enabled)
        .accessibilityLabel(captureActionLabel)

        if #available(macOS 26.0, *) {
            button.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            button.background(tint, in: Capsule())
        }
    }

    @ViewBuilder private var sidebarSettingsButton: some View {
        ArcoNativeActionButton(
            title: translate("nav.openSettings", [:]),
            symbol: "slider.horizontal.3",
            variant: .toolbar,
            action: { controller.openSettings() }
        )
        .frame(width: 40, height: 40)
        .focused($settingsTriggerFocused)
        .overlay(alignment: .topTrailing) {
            if controller.updateAvailable {
                Circle()
                    .fill(ArcoNativeColors.record)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(ArcoNativeColors.surfaceDocument, lineWidth: 1.5))
                    .offset(x: -2, y: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    private func pageStage(viewportWidth: CGFloat) -> some View {
        ZStack {
            ArcoStageArtwork().equatable()

            Group {
                switch controller.page {
                case .current: currentPage(viewportWidth: viewportWidth)
                case .history: historyPage(viewportWidth: viewportWidth)
                case .notes: notesPage(viewportWidth: viewportWidth)
                case .review: reviewPage(viewportWidth: viewportWidth)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ArcoLayoutMetrics.pageCornerRadius, style: .continuous))
        .overlay(ArcoStageBorder(cornerRadius: ArcoLayoutMetrics.pageCornerRadius))
        .accessibilityElement(children: .contain)
    }

    private func currentPage(viewportWidth: CGFloat) -> some View {
        VStack(spacing: 16) {
            if controller.store.capture.phase == .recording {
                TopBarView(
                    meeting: controller.currentMeeting?.summary,
                    meetingDetail: controller.currentMeeting,
                    capture: controller.store.capture,
                    viewModel: controller.topBarViewModel,
                    translate: translate
                )
                // The details card renders inside the TopBar's overlay; without
                // raising the whole bar the later workspace paints over it.
                .zIndex(1)
            }
            if controller.store.capture.phase == .recording {
                workspace(controller.currentMeeting, viewportWidth: viewportWidth)
            } else {
                idleWorkspace(viewportWidth: viewportWidth)
            }
        }
        .padding(.top, ArcoLayoutMetrics.titlebarClearance)
        .padding(
            .horizontal,
            ArcoLayoutMetrics.currentPageHorizontalPadding(viewportWidth: viewportWidth)
        )
        .padding(.bottom, ArcoLayoutMetrics.pageBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(translate("app.currentMeetingAria", [:]))
    }

    private func idleWorkspace(viewportWidth: CGFloat) -> some View {
        CurrentIdleView(
            capture: controller.store.capture,
            meetings: controller.store.meetings,
            audioMode: controller.displayedAudioMode,
            shortcut: controller.listeningShortcut,
            initializing: controller.store.loading,
            viewportWidth: viewportWidth,
            translate: translate,
            onStart: { Task { await controller.toggleCapture() } },
            onOpenAudioSettings: { controller.openSettings(.audio) }
        )
        .padding(ArcoLayoutMetrics.workspacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: ArcoLayoutMetrics.workspaceCornerRadius, style: .continuous)
                .strokeBorder(ArcoNativeColors.lineThin)
        )
    }

    private func historyPage(viewportWidth: CGFloat) -> some View {
        HistoryPageView(
            meetings: controller.store.meetings,
            selectedMeetingID: controller.store.selectedMeetingId,
            query: Binding(
                get: { controller.query },
                set: { value in controller.setQuery(value) }
            ),
            viewportWidth: viewportWidth,
            locale: Locale(identifier: controller.locale.rawValue),
            translate: translate,
            onSelectMeeting: { id in Task { await controller.selectMeeting(id) } }
        )
        .padding(.top, 0)
    }

    private func notesPage(viewportWidth: CGFloat) -> some View {
        NotesPageView(
            viewModel: controller.notesViewModel(),
            viewportWidth: viewportWidth,
            locale: Locale(identifier: controller.locale.rawValue),
            translate: translate
        )
            .padding(.top, 32)
            .padding(.bottom, 16)
    }

    private func reviewPage(viewportWidth: CGFloat) -> some View {
        VStack(spacing: 16) {
            TopBarView(
                meeting: controller.store.meeting?.summary,
                meetingDetail: controller.store.meeting,
                capture: controller.store.capture,
                viewModel: controller.topBarViewModel,
                translate: translate,
                onBackToHistory: { controller.requestPage(.history) }
            )
            // The details card renders inside the TopBar's overlay; without
            // raising the whole bar the later workspace paints over it.
            .zIndex(1)
            if controller.reviewingWhileRecording { liveReviewBanner }
            workspace(controller.store.meeting, viewportWidth: viewportWidth)
        }
        .padding(.top, ArcoLayoutMetrics.titlebarClearance)
        .padding(
            .horizontal,
            ArcoLayoutMetrics.currentPageHorizontalPadding(viewportWidth: viewportWidth)
        )
        .padding(.bottom, ArcoLayoutMetrics.pageBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(translate("app.historyReviewAria", [:]))
    }

    private var liveReviewBanner: some View {
        let active = controller.store.activeMeeting
        let title = active?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? translate(active == nil ? "common.currentMeeting" : "common.untitledMeeting", [:])
        return Button { Task { await controller.showPage(.current) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15))
                    .foregroundStyle(ArcoNativeColors.record)
                Text(translate("app.listeningContinues", [:]))
                    .font(ArcoTypography.sans(11, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.record)
                Text(title)
                    .font(ArcoTypography.metadata.weight(.medium))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(translate("app.returnToLive", [:]))
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkStrong)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                ArcoNativeColors.record.opacity(liveReviewHovered ? 0.19 : 0.10),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.985))
        .onHover { liveReviewHovered = $0 }
        .accessibilityLabel(translate("app.returnToLiveMeeting", ["title": title]))
    }

    private func workspace(_ meeting: MeetingDetail?, viewportWidth: CGFloat) -> some View {
        GeometryReader { proxy in
            let stacked = viewportWidth <= ArcoLayoutMetrics.workspaceStackedViewportBreakpoint
            Group {
                if stacked {
                    ScrollView {
                        VStack(spacing: ArcoLayoutMetrics.workspaceGap) {
                            transcriptDock(meeting)
                            .frame(minHeight: 380)
                            agentDock(meeting).frame(minHeight: 500)
                        }
                        .padding(ArcoLayoutMetrics.workspacePadding)
                    }
                } else {
                    let contentWidth = max(0, proxy.size.width - ArcoLayoutMetrics.workspacePadding * 2 - ArcoLayoutMetrics.workspaceGap)
                    let compactColumns = viewportWidth <= ArcoLayoutMetrics.compactViewportBreakpoint
                    let columns = ArcoLayoutMetrics.workspaceColumnWidths(
                        contentWidth: contentWidth,
                        compactColumns: compactColumns
                    )
                    HStack(spacing: ArcoLayoutMetrics.workspaceGap) {
                        transcriptDock(meeting)
                            .frame(width: columns.transcript)
                        agentDock(meeting)
                            .frame(width: columns.agent)
                    }
                    .padding(ArcoLayoutMetrics.workspacePadding)
                }
            }
            .background(ArcoNativeColors.stageFrame, in: RoundedRectangle(cornerRadius: ArcoLayoutMetrics.workspaceCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ArcoLayoutMetrics.workspaceCornerRadius).stroke(ArcoNativeColors.lineThin))
            .clipShape(RoundedRectangle(cornerRadius: ArcoLayoutMetrics.workspaceCornerRadius))
        }
    }

    private func transcriptDock(_ meeting: MeetingDetail?) -> some View {
        TranscriptPaneView(
            meeting: meeting,
            capture: controller.store.capture,
            loading: controller.store.loading,
            translate: translate
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(ArcoNativeColors.lineThin))
    }

    private func agentDock(_ meeting: MeetingDetail?) -> some View {
        let route = controller.providerRoute
        return InsightPanelView(
            meeting: meeting,
            replies: controller.store.agentReplies,
            runtimes: controller.store.runtimes,
            provider: route.provider,
            primaryProvider: controller.providerConfiguration.primary ?? route.provider,
            isFailover: route.isFailover,
            running: controller.store.agentRunning,
            workspace: controller.agentWorkspace,
            attachments: meeting.map { controller.store.attachments(for: $0.summary.id) } ?? [],
            live: controller.store.capture.phase == .recording && meeting?.summary.id == controller.store.capture.activeMeetingId,
            gptLiveBetaEnabled: controller.gptLiveBetaEnabled,
            gptLiveStatus: controller.gptLiveSession.status,
            showHeader: true,
            streamingTurn: controller.store.agentStreamingTurn,
            translate: translate,
            onAsk: { request in
                await controller.store.askAgent(AskAgentInput(
                    provider: request.provider,
                    usedFallback: request.usedFallback,
                    question: request.question,
                    agentPrompt: request.agentPrompt,
                    meetingId: request.meetingID,
                    workspace: request.workspace,
                    contextScope: request.contextScope.rawValue
                ))
            },
            onToggleSaved: { meetingID, turnID, saved in
                await controller.store.setAgentTurnSaved(meetingId: meetingID, turnId: turnID, saved: saved)
            },
            onChooseWorkspace: { await controller.chooseWorkspace() },
            onAttachDocument: { meetingID in
                await controller.attachDocument(to: meetingID)
            },
            onRemoveAttachment: { meetingID, attachmentID in
                await controller.removeAttachment(attachmentID, from: meetingID)
            },
            onCopy: controller.environment.copyText,
            onConnectAgent: controller.openProviderSetup,
            onToggleGPTLive: {
                Task { @MainActor in await controller.toggleGPTLive() }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(ArcoNativeColors.lineThin))
    }

    private func errorToast(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 17))
                .foregroundStyle(ArcoNativeColors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(translate("app.needsAttention", [:]))
                    .font(ArcoTypography.sans(12, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                Text(message)
                    .font(ArcoTypography.metadata)
                    .foregroundStyle(ArcoNativeColors.ink)
            }
            Button(action: controller.dismissError) {
                Image(systemName: "xmark")
                    .font(.system(size: 15))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.94))
            .foregroundStyle(ArcoNativeColors.inkMuted)
            .accessibilityLabel(translate("app.dismissError", [:]))
        }
        .padding(12)
        .frame(maxWidth: 380)
        .foregroundStyle(ArcoNativeColors.ink)
        .background(ArcoNativeColors.surfacePopover, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(0.03), radius: 1, y: 2)
        .shadow(color: Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(0.05), radius: 4, y: 4)
        .shadow(color: Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(0.10), radius: 10, y: 12)
        .accessibilityElement(children: .contain)
    }

    private var localeBinding: Binding<String> {
        Binding(
            get: { controller.locale.rawValue },
            set: { value in controller.changeLocale(value) }
        )
    }

    private var captureMode: (label: String, source: String) {
        switch controller.displayedAudioMode {
        case .both:
            (translate("capture.mode.hybrid", [:]), translate("capture.source.both", [:]))
        case .system:
            (translate("capture.mode.online", [:]), translate("capture.source.system", [:]))
        case .mic:
            (translate("capture.mode.room", [:]), translate("capture.source.room", [:]))
        }
    }

    private var captureStatus: String {
        if controller.store.loading { return translate("common.loading", [:]) }
        return switch controller.store.capture.phase {
        case .recording: translate("common.listening", [:])
        case .starting: translate("capture.starting", [:])
        case .stopping: translate("capture.stopping", [:])
        case .idle, .error: translate("capture.ready", [:])
        }
    }

    private var captureActionLabel: String {
        if controller.store.loading { return translate("common.loading", [:]) }
        return switch controller.store.capture.phase {
        case .recording: translate("capture.stop", [:])
        case .starting: translate("common.cancel", [:])
        case .stopping: translate("common.stopping", [:])
        case .idle, .error: translate(controller.page == .review ? "capture.continue" : "capture.start", [:])
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.key == "k", press.modifiers.contains(.command) || press.modifiers.contains(.control) {
            controller.closeSettingsWithoutRestoringFocus()
            controller.page = .history
            DispatchQueue.main.async { focusFirstTextField() }
            return .handled
        }
        if press.key == .escape {
            controller.closeSettings()
            return .handled
        }
        return .ignored
    }

    private func focusFirstTextField() {
        guard let root = NSApp.keyWindow?.contentView else { return }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, !field.isHidden { return field }
            for child in view.subviews {
                if let field = find(child) { return field }
            }
            return nil
        }
        if let field = find(root) { NSApp.keyWindow?.makeFirstResponder(field) }
    }
}

@_spi(Testing)
public enum ArcoStageGradientGeometry {
    public static func cssEndpoints(
        angleDegrees: Double,
        size: CGSize
    ) -> (start: CGPoint, end: CGPoint) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard size.width > 0, size.height > 0 else { return (center, center) }

        let radians = angleDegrees * Double.pi / 180
        let directionX = CGFloat(sin(radians))
        let directionY = CGFloat(-cos(radians))
        let halfLength = (
            abs(size.width * directionX) + abs(size.height * directionY)
        ) / 2

        return (
            start: CGPoint(
                x: center.x - directionX * halfLength,
                y: center.y - directionY * halfLength
            ),
            end: CGPoint(
                x: center.x + directionX * halfLength,
                y: center.y + directionY * halfLength
            )
        )
    }
}

private struct ArcoStageArtwork: View, Equatable {
    private static let matrixAngleDegrees: Double = 112
    private static let dotTileSize = CGSize(width: 8, height: 8)
    private static let dotCenter = CGPoint(x: 4, y: 4)
    private static let dotSolidRadius: CGFloat = 1
    private static let dotFadeRadius: CGFloat = 1.05
    private static let dotOverlayOpacity: Double = 0.38

    private static let dotTile = Image(
        size: dotTileSize,
        label: nil,
        opaque: false,
        colorMode: .nonLinear
    ) { context in
        let bounds = Path(CGRect(origin: .zero, size: dotTileSize))
        let solid = ArcoNativeColors.stageDot.opacity(dotOverlayOpacity)
        context.fill(
            bounds,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: solid, location: 0),
                    .init(color: solid, location: dotSolidRadius / dotFadeRadius),
                    .init(color: .clear, location: 1),
                ]),
                center: dotCenter,
                startRadius: 0,
                endRadius: dotFadeRadius
            )
        )
    }

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let boundsPath = Path(bounds)
            context.fill(boundsPath, with: .color(ArcoNativeColors.surfaceStageBase))
            context.withCGContext { graphics in
                Self.drawMatrixWash(in: graphics, size: size)
                Self.drawEllipticalWash(
                    in: graphics,
                    size: size,
                    red: 242,
                    green: 166,
                    blue: 144,
                    opacity: 0.20,
                    center: CGPoint(x: 0.88, y: 0.94),
                    radiusX: 0.62,
                    radiusY: 0.56,
                    fadeLocation: 0.74
                )
                Self.drawEllipticalWash(
                    in: graphics,
                    size: size,
                    red: 187,
                    green: 174,
                    blue: 238,
                    opacity: 0.18,
                    center: CGPoint(x: 0.88, y: 0.12),
                    radiusX: 0.58,
                    radiusY: 0.52,
                    fadeLocation: 0.76
                )
                Self.drawEllipticalWash(
                    in: graphics,
                    size: size,
                    red: 111,
                    green: 201,
                    blue: 236,
                    opacity: 0.28,
                    center: CGPoint(x: 0.14, y: 0.08),
                    radiusX: 0.78,
                    radiusY: 0.64,
                    fadeLocation: 0.72
                )
            }
            context.fill(
                boundsPath,
                with: .tiledImage(
                    Self.dotTile,
                    origin: .zero,
                    sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                    scale: 1
                )
            )
        }
        .allowsHitTesting(false)
    }

    private static func drawMatrixWash(in graphics: CGContext, size: CGSize) {
        let colors = [
            color(red: 100, green: 201, blue: 238, opacity: 0.24),
            color(red: 137, green: 204, blue: 244, opacity: 0.14),
            color(red: 177, green: 157, blue: 240, opacity: 0.14),
            color(red: 249, green: 169, blue: 145, opacity: 0.20),
        ]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 0.34, 0.64, 1]
        ) else { return }
        let endpoints = ArcoStageGradientGeometry.cssEndpoints(
            angleDegrees: matrixAngleDegrees,
            size: size
        )
        graphics.drawLinearGradient(
            gradient,
            start: endpoints.start,
            end: endpoints.end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private static func drawEllipticalWash(
        in graphics: CGContext,
        size: CGSize,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        opacity: CGFloat,
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        fadeLocation: CGFloat
    ) {
        let solid = color(red: red, green: green, blue: blue, opacity: opacity)
        let transparent = color(red: red, green: green, blue: blue, opacity: 0)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [solid, transparent] as CFArray,
            locations: [0, fadeLocation]
        ) else { return }

        graphics.saveGState()
        graphics.translateBy(x: size.width * center.x, y: size.height * center.y)
        graphics.scaleBy(
            x: max(1, size.width * radiusX),
            y: max(1, size.height * radiusY)
        )
        graphics.drawRadialGradient(
            gradient,
            startCenter: .zero,
            startRadius: 0,
            endCenter: .zero,
            endRadius: 1,
            options: [.drawsAfterEndLocation]
        )
        graphics.restoreGState()
    }

    private static func color(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        opacity: CGFloat
    ) -> CGColor {
        CGColor(
            red: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: opacity
        )
    }
}

private struct ArcoStageBorder: View {
    var cornerRadius: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(ArcoNativeColors.lineThin)
                    .frame(width: 1, height: geometry.size.height)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(ArcoNativeColors.line)
                    .frame(width: 1, height: geometry.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Rectangle()
                    .fill(ArcoNativeColors.lineThin)
                    .frame(width: geometry.size.width, height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rectangle()
                    .fill(ArcoNativeColors.lineThin)
                    .frame(width: geometry.size.width, height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

private struct SidebarNavigationButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarNavigationButton(configuration: configuration, selected: selected)
    }
}

private struct SidebarNavigationButton: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        configuration.label
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(
                configuration.isPressed && isEnabled && !accessibilityReduceMotion ? 0.985 : 1
            )
            .opacity(configuration.isPressed && isEnabled ? 0.84 : 1)
            .onHover { hovered = $0 }
            .animation(accessibilityReduceMotion ? nil : ArcoMotion.hover, value: hovered)
            .animation(
                accessibilityReduceMotion ? .easeOut(duration: 0.08) : ArcoMotion.press,
                value: configuration.isPressed
            )
    }

    private var background: Color {
        if selected { return Color.white.opacity(0.72) }
        if hovered && isEnabled { return Color.white.opacity(0.34) }
        return .clear
    }
}

private struct ArcoAppStoreSynchronizationModifier: ViewModifier {
    @ObservedObject var controller: ArcoAppShellController
    @State private var initialized = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !initialized else { return }
                initialized = true
                await controller.initialize()
            }
            .modifier(ArcoNavigationSynchronizationModifier(controller: controller))
            .modifier(ArcoContentSynchronizationModifier(controller: controller))
            .modifier(ArcoCredentialSynchronizationModifier(controller: controller))
            .modifier(ArcoStorageSynchronizationModifier(controller: controller))
    }
}

private struct ArcoNavigationSynchronizationModifier: ViewModifier {
    @ObservedObject var controller: ArcoAppShellController

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.store.completedMeetingId) { _, _ in completedMeetingChanged() }
            .onChange(of: controller.store.capture.phase) { _, _ in
                completedMeetingChanged()
                controller.updateDependentViewModels()
            }
            .onChange(of: controller.store.selectedMeetingId) { _, _ in completedMeetingChanged() }
            .onChange(of: controller.store.meeting?.summary.id) { _, _ in completedMeetingChanged() }
    }

    private func completedMeetingChanged() {
        controller.captureCompletedMeetingChanged()
    }
}

private struct ArcoContentSynchronizationModifier: ViewModifier {
    @ObservedObject var controller: ArcoAppShellController

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.store.savedNotes) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.meetings) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.notesLoading) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.transcriptionModels) { _, _ in controller.updateDependentViewModels() }
    }
}

private struct ArcoCredentialSynchronizationModifier: ViewModifier {
    @ObservedObject var controller: ArcoAppShellController

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.store.deepgramCredential) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.elevenLabsCredential) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.doubaoCredential) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.deepgramCredentialBusy) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.elevenLabsCredentialBusy) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.doubaoCredentialBusy) { _, _ in controller.updateDependentViewModels() }
    }
}

private struct ArcoStorageSynchronizationModifier: ViewModifier {
    @ObservedObject var controller: ArcoAppShellController

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.store.storageSettings) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.notesStorageSettings) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.storageChanging) { _, _ in controller.updateDependentViewModels() }
            .onChange(of: controller.store.notesStorageChanging) { _, _ in controller.updateDependentViewModels() }
    }
}
