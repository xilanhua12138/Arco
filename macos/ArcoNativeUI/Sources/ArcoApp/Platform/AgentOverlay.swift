import AppKit
import ArcoNativeUI
import Foundation
import Observation
import SwiftUI

private enum AgentOverlaySourcePalette {
    static let transcriptHeader = Color(
        red: 119 / 255,
        green: 119 / 255,
        blue: 119 / 255
    ).opacity(0.03)
}

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

    static let empty = AgentOverlaySnapshot(
        meeting: nil,
        capture: .idle,
        replies: [],
        runtimes: [],
        providerConfiguration: ProviderConfiguration(),
        running: false,
        streamingTurn: nil,
        loading: true,
        workspace: nil
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
    private var refreshGeneration = 0

    init(
        snapshot: AgentOverlaySnapshot = .empty,
        loadActiveSnapshot: @escaping () async throws -> AgentOverlaySnapshot,
        runAsk: @escaping (InsightAskRequest) async throws -> Bool,
        toggleSaved: @escaping (String, String, Bool) async -> Bool,
        chooseWorkspace: @escaping () async -> String?
    ) {
        self.snapshot = snapshot
        self.loadActiveSnapshot = loadActiveSnapshot
        self.runAsk = runAsk
        self.toggleSaved = toggleSaved
        self.chooseWorkspaceAction = chooseWorkspace
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
}

struct AgentOverlaySurfaceView: View {
    @Bindable var model: AgentOverlayModel
    @Binding var transcriptVisible: Bool
    let translate: ArcoTranslate
    let onHide: @MainActor () -> Void
    let onFocusMain: @MainActor () throws -> Void
    let onError: @MainActor (Error) -> Void

    init(
        model: AgentOverlayModel,
        transcriptVisible: Binding<Bool>,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onHide: @escaping @MainActor () -> Void,
        onFocusMain: @escaping @MainActor () throws -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.model = model
        self._transcriptVisible = transcriptVisible
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
        model.snapshot.capture.phase == .recording
            && model.snapshot.meeting?.summary.id
                == model.snapshot.capture.activeMeetingId
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

    @ViewBuilder
    private var header: some View {
        if transcriptVisible {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    agentHeader
                        .frame(width: geometry.size.width * 3 / 5)
                    transcriptHeader
                        .frame(width: geometry.size.width * 2 / 5)
                }
            }
            .background(Color(red: 248 / 255, green: 251 / 255, blue: 253 / 255).opacity(0.4))
            .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
        } else {
            agentHeader
                .background(Color(red: 248 / 255, green: 251 / 255, blue: 253 / 255).opacity(0.4))
                .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
        }
    }

    private var agentHeader: some View {
        HStack(spacing: 10) {
            Text(translate("agent.askArco", [:]))
                .font(ArcoTypography.sans(15, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .tracking(-0.15)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !transcriptVisible {
                HStack(spacing: 4) {
                    Button {
                        transcriptVisible = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 15))
                            Text(translate("transcript.heading", [:]))
                                .font(ArcoTypography.sans(11))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                    }
                    .buttonStyle(AgentHeaderButtonStyle())
                    .accessibilityLabel(translate("agent.showTranscript", [:]))

                    closeButton
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 11)
        .background(ArcoWindowDragRegion())
    }

    private var transcriptHeader: some View {
        HStack(spacing: 10) {
            Text(translate("transcript.heading", [:]))
                .font(ArcoTypography.sans(13, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if live {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(ArcoNativeColors.record)
                            .frame(width: 6, height: 6)
                        Text(translate("agent.live", [:]))
                            .font(ArcoTypography.sans(11, weight: .medium))
                    }
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                }

                Button {
                    transcriptVisible = false
                } label: {
                    Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(AgentHeaderButtonStyle())
                .accessibilityLabel(translate("agent.hideTranscript", [:]))

                closeButton
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 11)
        .background(AgentOverlaySourcePalette.transcriptHeader)
        .background(ArcoWindowDragRegion())
        .overlay(alignment: .leading) { ArcoNativeColors.lineThin.frame(width: 1) }
    }

    private var closeButton: some View {
        Button(action: onHide) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(AgentCloseButtonStyle())
        .padding(.leading, 7)
        .overlay(alignment: .leading) {
            ArcoNativeColors.lineThin
                .frame(width: 1, height: 20)
        }
        .accessibilityLabel(translate("agent.close", [:]))
    }

    @ViewBuilder
    private var workspace: some View {
        if transcriptVisible {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    agentSlot
                        .frame(width: geometry.size.width * 3 / 5)
                    TranscriptPaneView(
                        meeting: model.snapshot.meeting,
                        capture: model.snapshot.capture,
                        loading: model.snapshot.loading,
                        compact: true,
                        showHeader: false,
                        layout: .agentOverlay,
                        translate: translate
                    )
                    .frame(width: geometry.size.width * 2 / 5)
                    .background(
                        Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255)
                            .opacity(0.9)
                    )
                    .overlay(alignment: .leading) {
                        ArcoNativeColors.lineThin.frame(width: 1)
                    }
                }
            }
        } else {
            agentSlot
        }
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
            VStack(spacing: 8) {
                Text(translate("agent.askArco", [:]))
                    .font(ArcoTypography.sans(20, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                Text(translate("agent.connectFirst", [:]))
                    .font(ArcoTypography.sans(13))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                Button(translate("agent.openArco", [:])) {
                    do {
                        try onFocusMain()
                    } catch {
                        onError(error)
                    }
                }
                .buttonStyle(AgentPrimaryGlassButtonStyle())
                .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.92))
        }
    }
}

private struct AgentHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentHeaderButtonBody(configuration: configuration)
    }
}

private struct AgentCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentHeaderButtonBody(configuration: configuration)
    }
}

private struct AgentHeaderButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    @ViewBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if #available(macOS 26.0, *) {
            configuration.label
                .foregroundStyle(hovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                .contentShape(shape)
                .glassEffect(
                    .regular
                        .tint(hovering ? ArcoNativeColors.surfaceHover : nil)
                        .interactive(),
                    in: shape
                )
                .onHover { hovering = $0 }
        } else {
            configuration.label
                .foregroundStyle(hovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                .background(hovering ? ArcoNativeColors.surfaceHover : Color.clear)
                .clipShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

private struct AgentPrimaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AgentPrimaryGlassButtonBody(configuration: configuration)
    }
}

private struct AgentPrimaryGlassButtonBody: View {
    let configuration: ButtonStyle.Configuration

    @ViewBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if #available(macOS 26.0, *) {
            configuration.label
                .font(ArcoTypography.sans(13))
                .foregroundStyle(ArcoNativeColors.actionInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(shape)
                .glassEffect(
                    .regular.tint(ArcoNativeColors.action).interactive(),
                    in: shape
                )
        } else {
            configuration.label
                .font(ArcoTypography.sans(13))
                .foregroundStyle(ArcoNativeColors.actionInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ArcoNativeColors.action, in: shape)
        }
    }
}
