import AppKit
import ArcoNativeUI
import Foundation
import Observation
import SwiftUI

struct AgentOverlaySnapshot: Equatable, Sendable {
    var meeting: MeetingDetail?
    var capture: CaptureState
    var replies: [AgentTurn]
    var runtimes: [RuntimeStatus]
    var providerConfiguration: ProviderConfiguration
    var running: Bool
    var streamingTurn: AgentStreamingTurn?
    var loading: Bool
    var workspace: String?
    var attachments: [MeetingAttachment]

    static let empty = AgentOverlaySnapshot(
        meeting: nil,
        capture: .idle,
        replies: [],
        runtimes: [],
        providerConfiguration: ProviderConfiguration(),
        running: false,
        streamingTurn: nil,
        loading: true,
        workspace: nil,
        attachments: []
    )
}

/// The overlay intentionally owns a snapshot of the active meeting instead of
/// borrowing the main window's selected meeting. Reviewing history in the
/// main window therefore never redirects Ask
/// Arco away from the currently recording meeting.
@MainActor
@Observable
final class AgentOverlayModel {
    private(set) var snapshot: AgentOverlaySnapshot
    private(set) var error: String?

    private let loadActiveSnapshot: () async throws -> AgentOverlaySnapshot
    private let runAsk: (InsightAskRequest) async throws -> Bool
    private let toggleSaved: (String, String, Bool) async -> Bool
    private let chooseWorkspaceAction: () async -> String?
    private let attachDocumentAction: (String) async -> Bool
    private let removeAttachmentAction: (String, String) async -> Void
    private var refreshGeneration = 0

    init(
        snapshot: AgentOverlaySnapshot = .empty,
        loadActiveSnapshot: @escaping () async throws -> AgentOverlaySnapshot,
        runAsk: @escaping (InsightAskRequest) async throws -> Bool,
        toggleSaved: @escaping (String, String, Bool) async -> Bool,
        chooseWorkspace: @escaping () async -> String?,
        attachDocument: @escaping (String) async -> Bool = { _ in false },
        removeAttachment: @escaping (String, String) async -> Void = { _, _ in }
    ) {
        self.snapshot = snapshot
        self.loadActiveSnapshot = loadActiveSnapshot
        self.runAsk = runAsk
        self.toggleSaved = toggleSaved
        self.chooseWorkspaceAction = chooseWorkspace
        self.attachDocumentAction = attachDocument
        self.removeAttachmentAction = removeAttachment
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let next = try await loadActiveSnapshot()
            guard generation == refreshGeneration else { return }
            snapshot = next
            error = nil
        } catch {
            guard generation == refreshGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    /// Lets the app's backend event listener update the live stream without
    /// waiting for the next focus refresh.
    func apply(_ next: AgentOverlaySnapshot) {
        snapshot = next
    }

    func applyStreamingTurn(_ turn: AgentStreamingTurn?) {
        snapshot.streamingTurn = turn
    }

    func applyRunning(_ running: Bool) {
        snapshot.running = running
    }

    func ask(_ request: InsightAskRequest) async throws -> Bool {
        guard !snapshot.running else { return false }
        snapshot.running = true
        defer { snapshot.running = false }
        let succeeded = try await runAsk(request)
        if succeeded { await refresh() }
        return succeeded
    }

    func setSaved(meetingID: String, turnID: String, saved: Bool) async -> Bool {
        let succeeded = await toggleSaved(meetingID, turnID, saved)
        guard succeeded else { return false }
        snapshot.replies = snapshot.replies.map { turn in
            guard turn.id == turnID else { return turn }
            var next = turn
            next.savedAsNote = saved
            return next
        }
        return true
    }

    func chooseWorkspace() async -> String? {
        guard let workspace = await chooseWorkspaceAction() else { return nil }
        snapshot.workspace = workspace
        return workspace
    }

    func attachDocument(to meetingID: String) async -> Bool {
        let succeeded = await attachDocumentAction(meetingID)
        if succeeded { await refresh() }
        return succeeded
    }

    func removeAttachment(_ attachmentID: String, from meetingID: String) async {
        await removeAttachmentAction(meetingID, attachmentID)
        snapshot.attachments = snapshot.attachments.filter { $0.id != attachmentID }
    }
}

struct AgentOverlaySurfaceView: View {
    @Bindable var model: AgentOverlayModel
    @Binding var transcriptVisible: Bool
    let transcriptMeeting: MeetingDetail?
    let transcriptCapture: CaptureState
    let transcriptLoading: Bool
    let translate: ArcoTranslate
    let onHide: @MainActor () -> Void
    let onFocusMain: @MainActor () throws -> Void
    let onError: @MainActor (Error) -> Void

    init(
        model: AgentOverlayModel,
        transcriptVisible: Binding<Bool>,
        transcriptMeeting: MeetingDetail?,
        transcriptCapture: CaptureState,
        transcriptLoading: Bool,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onHide: @escaping @MainActor () -> Void,
        onFocusMain: @escaping @MainActor () throws -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.model = model
        self._transcriptVisible = transcriptVisible
        self.transcriptMeeting = transcriptMeeting
        self.transcriptCapture = transcriptCapture
        self.transcriptLoading = transcriptLoading
        self.translate = translate
        self.onHide = onHide
        self.onFocusMain = onFocusMain
        self.onError = onError
    }

    private var route: ProviderRoute {
        ProviderRoute.resolve(
            config: model.snapshot.providerConfiguration,
            runtimes: model.snapshot.runtimes
        )
    }

    private var live: Bool {
        transcriptCapture.phase == .recording
            && transcriptMeeting?.summary.id
                == transcriptCapture.activeMeetingId
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 52)
            workspace
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("agent.askArco", [:]))
    }

    private var header: some View {
        GeometryReader { geometry in
            if transcriptVisible {
                HStack(spacing: 0) {
                    agentHeader
                        .frame(
                            width: geometry.size.width * 3 / 5,
                            height: geometry.size.height,
                            alignment: .center
                        )
                        .background(ArcoWindowDragRegion())
                    transcriptHeader
                        .frame(
                            width: geometry.size.width * 2 / 5,
                            height: geometry.size.height,
                            alignment: .center
                        )
                        .background(ArcoWindowDragRegion())
                }
            } else {
                agentHeader
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .center
                    )
                    .background(ArcoWindowDragRegion())
            }
        }
        .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 0.5) }
    }

    private var agentHeader: some View {
        HStack(spacing: 10) {
            Text(translate("agent.askArco", [:]))
                .font(ArcoTypography.sans(15, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .tracking(-0.15)
                .lineLimit(1)
                .frame(height: 22, alignment: .center)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !transcriptVisible {
                HStack(spacing: 6) {
                    AgentHeaderToggleButton(
                        symbol: "sidebar.trailing",
                        symbolSize: 15,
                        label: translate("agent.showTranscript", [:]),
                        action: { transcriptVisible = true }
                    )

                    closeButton
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 11)
    }

    private var transcriptHeader: some View {
        HStack(spacing: 10) {
            Text(translate("transcript.heading", [:]))
                .font(ArcoTypography.sans(13, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .tracking(-0.13)
                .lineLimit(1)
                .frame(height: 22, alignment: .center)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if live {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(ArcoNativeColors.record)
                            .frame(width: 6, height: 6)
                        Text(translate("agent.live", [:]))
                            .font(ArcoTypography.sans(11, weight: .medium))
                    }
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .frame(height: 22, alignment: .center)
                    .padding(.trailing, 4)
                }

                AgentHeaderToggleButton(
                    symbol: "sidebar.trailing",
                    symbolSize: 15,
                    label: translate("agent.hideTranscript", [:]),
                    action: { transcriptVisible = false }
                )

                closeButton
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 11)
    }

    private var closeButton: some View {
        AgentHeaderCloseButton(
            symbol: "xmark",
            symbolSize: 14,
            symbolWeight: .regular,
            label: translate("agent.close", [:]),
            action: onHide
        )
    }

    private var workspace: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                agentSlot
                    .frame(
                        width: transcriptVisible
                            ? geometry.size.width * 3 / 5
                            : geometry.size.width
                    )
                if transcriptVisible {
                    TranscriptPaneView(
                        meeting: transcriptMeeting,
                        capture: transcriptCapture,
                        loading: transcriptLoading,
                        compact: true,
                        showHeader: false,
                        layout: .agentOverlay,
                        translate: translate
                    )
                    .frame(width: geometry.size.width * 2 / 5)
                    .background(Color.white.opacity(0.18))
                    .overlay(alignment: .leading) {
                        ArcoNativeColors.line.frame(width: 0.5)
                    }
                }
            }
        }
        .background(ArcoNativeColors.surfaceDocument.opacity(0.92))
    }

    @ViewBuilder
    private var agentSlot: some View {
        if route.provider != nil {
            InsightPanelView(
                meeting: model.snapshot.meeting,
                replies: model.snapshot.replies,
                runtimes: model.snapshot.runtimes,
                provider: route.provider,
                primaryProvider: model.snapshot.providerConfiguration.primary ?? route.provider,
                isFailover: route.isFailover,
                running: model.snapshot.running,
                workspace: model.snapshot.workspace,
                attachments: model.snapshot.attachments,
                live: live,
                showHeader: false,
                layout: .agentOverlay,
                streamingTurn: model.snapshot.streamingTurn,
                translate: translate,
                onAsk: { request in
                    try await model.ask(request)
                },
                onToggleSaved: { meetingID, turnID, saved in
                    await model.setSaved(
                        meetingID: meetingID,
                        turnID: turnID,
                        saved: saved
                    )
                },
                onChooseWorkspace: {
                    await model.chooseWorkspace()
                },
                onAttachDocument: { meetingID in
                    await model.attachDocument(to: meetingID)
                },
                onRemoveAttachment: { meetingID, attachmentID in
                    await model.removeAttachment(attachmentID, from: meetingID)
                },
                onCopy: { text in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    guard pasteboard.setString(text, forType: .string) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
            .id(model.snapshot.meeting?.summary.id ?? "no-meeting")
        } else {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.36))
                        .overlay(Circle().strokeBorder(ArcoNativeColors.line, lineWidth: 0.75))
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.ink)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                Text(translate("agent.connectFirst", [:]))
                    .font(ArcoTypography.sans(13))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .lineSpacing(3.6)
                    .frame(maxWidth: 260)
                    .padding(.top, 12)
                Button(translate("agent.openArco", [:])) {
                    do {
                        try onFocusMain()
                    } catch {
                        onError(error)
                    }
                }
                .buttonStyle(AgentPrimaryOverlayButtonStyle())
                .padding(.top, 16)
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.32))
        }
    }
}

private struct AgentHeaderToggleButton: View {
    let symbol: String
    let symbolSize: CGFloat
    let label: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(AgentHeaderToggleButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct AgentHeaderCloseButton: View {
    let symbol: String
    let symbolSize: CGFloat
    var symbolWeight: Font.Weight = .regular
    let label: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: symbolWeight))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(AgentHeaderCloseButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct AgentHeaderToggleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentHeaderToggleButtonBody(configuration: configuration)
    }
}

private struct AgentHeaderToggleButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .foregroundStyle(hovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
            .contentShape(shape)
            .background(
                hovering || configuration.isPressed
                    ? ArcoNativeColors.surfaceHover
                    : Color.clear,
                in: shape
            )
            .onHover { hovering = $0 }
    }
}

private struct AgentHeaderCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentHeaderCloseButtonBody(configuration: configuration)
    }
}

private struct AgentHeaderCloseButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        let shape = Circle()
        configuration.label
            .foregroundStyle(hovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
            .contentShape(shape)
            .background(
                hovering || configuration.isPressed
                    ? Color.white.opacity(0.56)
                    : Color.white.opacity(0.36),
                in: shape
            )
            .overlay(shape.strokeBorder(ArcoNativeColors.line, lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.06), radius: 1, y: 1)
            .onHover { hovering = $0 }
    }
}

private struct AgentPrimaryOverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentPrimaryOverlayButtonBody(configuration: configuration)
    }
}

private struct AgentPrimaryOverlayButtonBody: View {
    let configuration: ButtonStyle.Configuration

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(ArcoTypography.sans(13))
            .foregroundStyle(ArcoNativeColors.actionInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(shape)
            .background(ArcoNativeColors.action, in: shape)
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}
