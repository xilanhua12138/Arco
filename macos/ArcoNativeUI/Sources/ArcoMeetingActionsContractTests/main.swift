import AppKit
import SwiftUI
@_spi(Testing) import ArcoNativeUI

private final class EmptyBackend: BackendDispatching, @unchecked Sendable {
    func request(_ command: String, arguments: [String: AnySendable]) async throws -> Data { Data("{}".utf8) }
    func setEventHandler(_ handler: (@Sendable (BackendEvent) -> Void)?) {}
}

@main struct MeetingActionsCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); NSApp.terminate(nil) }
            catch { print("Action checks failed: \(error)"); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARCO_ACTIONS_SNAPSHOTS"] ?? "/tmp/arco-meeting-actions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let translate = ArcoTranslations.translator(for: .simplifiedChinese)
        let defaults = UserDefaults(suiteName: "arco.actions.fixture.\(UUID().uuidString)")!
        let preferences = ArcoPreferences(store: UserDefaultsKeyValueStore(defaults: defaults))
        preferences.saveGPTLiveBetaEnabled(true)
        let store = ArcoStore(backend: EmptyBackend())
        let controller = ArcoAppShellController(store: store, preferences: preferences, translate: translate)
        let capture = CaptureState(phase: .recording, activeMeetingId: "fixture", startedAt: "2026-09-15T10:00:00Z",
            message: nil, mode: .both, transcriptPath: nil, error: nil, transcription: nil)
        let model = RecordingHUDModel(readCapture: { capture }, stopCapture: { capture }, onStopped: {})
        model.startMonitoring()
        try await Task.sleep(for: .milliseconds(50))
        defer { model.stopMonitoring() }
        try await render(RecordingHUDView(model: model, controller: controller, translate: translate, onToggleAgent: { true })
            .background(ArcoNativeColors.surfaceSubtle, in: RoundedRectangle(cornerRadius: 14)),
            to: directory.appendingPathComponent("hud.png"))
        try await render(RecordingHUDView(model: model, controller: controller, onToggleAgent: { true })
            .background(ArcoNativeColors.surfaceSubtle, in: RoundedRectangle(cornerRadius: 14)),
            to: directory.appendingPathComponent("hud-english.png"))
        model.agentWindowVisible = true
        try await render(RecordingHUDView(model: model, controller: controller, translate: translate, onToggleAgent: { false })
            .background(ArcoNativeColors.surfaceSubtle, in: RoundedRectangle(cornerRadius: 14)),
            to: directory.appendingPathComponent("hud-ask-open.png"))
        model.agentWindowVisible = false
        for locale in [AppLocale.simplifiedChinese, .english] {
            let t = ArcoTranslations.translator(for: locale)
            let width = GPTLiveButtonPresentation.maximumRevealWidth(translate: t)
            for phase in [GPTLiveSessionPhase.idle, .connecting, .connected, .failed, .disconnecting] {
                precondition(width >= ArcoMeetingActionButton.labelRevealWidth(t(GPTLiveButtonPresentation.labelKey(for: phase), [:])))
            }
            try await render(HStack(spacing: 8) {
                ArcoMeetingActionButton(title: t("hud.askArco", [:]), symbol: "text.bubble", compact: true,
                    iconOnly: true, revealLabel: true) {}
                GPTLiveBetaButton(status: .idle, translate: t, compact: true, iconOnly: true, revealLabel: true) {}
            }.padding(16).background(Color.white), to: directory.appendingPathComponent("expanded-\(locale.rawValue).png"))
        }
        for phase in [GPTLiveSessionPhase.idle, .connecting, .connected, .failed, .disconnecting] {
            let row = HStack(spacing: 8) {
                ArcoMeetingActionButton(title: translate("agent.askArco", [:]), symbol: "text.bubble") {}
                GPTLiveBetaButton(status: GPTLiveSessionStatus(phase: phase), translate: translate) {}
            }.padding(16).background(Color.white)
            try await render(row, to: directory.appendingPathComponent("actions-\(phase.rawValue).png"))
        }
        let summary = MeetingSummary(id: "fixture", title: "产品评审与本周工作安排", generatedSummary: nil,
            titleGenerationStatus: "idle", summaryGenerationStatus: "idle", startedAt: "2026-09-15T10:00:00Z",
            durationLabel: "10:24", preview: "", path: "/tmp/fixture.md", utteranceCount: 3, isLive: true, source: "both")
        for width: CGFloat in [680, 736, 896] {
            let header = HStack(spacing: 12) {
                TopBarView(meeting: summary, capture: capture, viewModel: TopBarViewModel(onRenameMeeting: { _, _ in true }), translate: translate)
                HStack(spacing: 8) {
                    ArcoMeetingActionButton(title: translate("agent.askArco", [:]), symbol: "text.bubble", iconOnly: width < 740) {}
                    GPTLiveBetaButton(status: .idle, translate: translate, iconOnly: width < 740) {}
                }
            }.frame(width: width).padding(16).background(Color.white)
            try await render(header, to: directory.appendingPathComponent("header-\(Int(width)).png"))
        }
        for phase in [GPTLiveSessionPhase.idle, .connecting, .connected, .failed] {
            try await render(GPTLiveBetaButton(status: GPTLiveSessionStatus(phase: phase), compact: true, iconOnly: true) {}
                .padding(16).background(Color.white), to: directory.appendingPathComponent("english-\(phase.rawValue).png"))
        }
        precondition(GPTLiveButtonPresentation.isEnabled(for: .connected), "Connected entry must still open participant status")
        precondition(GPTLiveButtonPresentation.isEnabled(for: .connecting), "Joining entry must reveal the pending participant")
        precondition(!GPTLiveButtonPresentation.isEnabled(for: .disconnecting), "Departure must prevent duplicate invitations")
        precondition(GPTLiveButtonPresentation.labelKey(for: .failed) == "agent.gptLiveRetry")
        print("PASS: participant entry states; rendered actual HUD and peer actions to \(directory.path)")
        if Bundle.main.bundleIdentifier == "app.arco.hud-review" {
            let panel = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 328, height: 52),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.title = "Arco hover review"
            panel.contentView = NSHostingView(rootView: RecordingHUDView(model: model, controller: controller,
                translate: translate, onToggleAgent: { true }, onWidthChange: { width, animated in
                    var frame = panel.frame
                    frame.size.width = width
                    panel.setFrame(frame, display: true, animate: animated)
                }).background(ArcoNativeColors.surfaceSubtle))
            NSApp.setActivationPolicy(.regular)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            while panel.isVisible { try await Task.sleep(for: .milliseconds(200)) }
        }

    }
    @MainActor static func render<V: View>(_ view: V, to url: URL) async throws {
        if url.lastPathComponent.hasPrefix("header-") {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "FixtureRendering", code: 2) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            return
        }
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FixtureRendering", code: 1)
        }
        try png.write(to: url)
    }
}
