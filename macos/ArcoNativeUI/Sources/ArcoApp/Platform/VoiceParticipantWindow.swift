import AppKit
import SwiftUI
import ArcoNativeUI

extension WindowCoordinator {
    func showVoiceParticipant(controller: ArcoAppShellController, translate: @escaping ArcoTranslate) {
        onVoiceParticipantClosed = { [weak controller] in controller?.hideVoiceParticipant() }
        if voiceParticipantWindow == nil {
            let panel = VoiceParticipantPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 392),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = translate("agent.gptLiveConnect", [:])
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = false
            panel.isMovable = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: VoiceParticipantContent(
                controller: controller, session: controller.gptLiveSession, translate: translate,
                close: { [weak self] in
                    self?.onVoiceParticipantClosed()
                    self?.voiceParticipantWindow?.orderOut(nil)
                }))
            let restored = panel.setFrameUsingName("ArcoVoiceParticipant")
            panel.setContentSize(NSSize(width: 300, height: 392))
            if let screen = mainWindow?.screen ?? NSScreen.main {
                let area = screen.visibleFrame
                let origin = restored ? panel.frame.origin : NSPoint(x: area.maxX - 324, y: area.maxY - 420)
                panel.setFrameOrigin(NSPoint(x: min(max(origin.x, area.minX), area.maxX - 300),
                                             y: min(max(origin.y, area.minY), area.maxY - 392)))
            }
            voiceParticipantWindow = panel
        }
        voiceParticipantWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct VoiceParticipantContent: View {
    @ObservedObject var controller: ArcoAppShellController
    @ObservedObject var session: GPTLiveSessionModel
    let translate: ArcoTranslate
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(session.status.phase == .connected ? Color.cyan : Color.white.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text("Arco").font(ArcoTypography.sans(13, weight: .semibold))
                    Spacer()
                }
                .frame(height: 24)
                .overlay(VoiceTitleDragRegion())
                Button(action: close) {
                    Image(systemName: "minus").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55)).frame(width: 24, height: 24)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(translate("agent.voiceHide", [:]))
                .help(translate("agent.voiceHideHelp", [:]))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16).padding(.top, 12)
            ArcoVoicePresence(status: controller.voiceParticipantStatus, translate: translate)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Label(translate(session.status.meetingOutput ? "agent.voiceMeetingOutput" : "agent.voiceLocalOutput", [:]),
                      systemImage: session.status.meetingOutput ? "mic" : "speaker.wave.2")
                    .font(ArcoTypography.sans(10)).foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                Button {
                    Task { @MainActor in
                        if controller.voiceInvitationPreparing || [.connecting, .connected].contains(session.status.phase) {
                            await controller.leaveArco()
                        } else { await controller.inviteArco() }
                    }
                } label: {
                    Text(translate(actionKey, [:]))
                        .font(ArcoTypography.sans(11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(session.status.phase == .disconnecting)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 300, height: 392)
        .background(Color(red: 0.025, green: 0.035, blue: 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
    private var actionKey: String {
        if controller.voiceInvitationPreparing { return "agent.gptLiveCancel" }
        return switch session.status.phase {
        case .idle: "agent.gptLiveConnect"
        case .failed: "agent.gptLiveRetry"
        case .connecting: "agent.gptLiveCancel"
        case .disconnecting: "agent.gptLiveDisconnecting"
        case .connected: "agent.gptLiveListening"
        }
    }
}

private final class VoiceParticipantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct VoiceTitleDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
