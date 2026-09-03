import AppKit
import ArcoNativeUI
import Observation
import SwiftUI

enum WindowCoordinatorError: LocalizedError {
    case contentNotInstalled(String)
    case noAvailableDisplay
    case agentUnavailable

    var errorDescription: String? {
        switch self {
        case let .contentNotInstalled(surface):
            "Arco could not create its \(surface) window because its content is not installed."
        case .noAvailableDisplay:
            "Arco could not find an available display."
        case .agentUnavailable:
            "Start listening before opening Ask Arco"
        }
    }
}

struct HUDWindowActions {
    let toggleAgent: @MainActor () throws -> Bool
}

struct AgentWindowActions {
    let hide: @MainActor () -> Void
    let focusMain: @MainActor () throws -> Void
}

struct WindowContentFactories {
    var main: (@MainActor () throws -> AnyView)?
    var hud: (@MainActor (HUDWindowActions) throws -> AnyView)?
    var agent: (@MainActor (Binding<Bool>, AgentWindowActions) throws -> AnyView)?
    var meetingPrompt: (@MainActor (DetectedMeeting) throws -> AnyView)?

    init(
        main: (@MainActor () throws -> AnyView)? = nil,
        hud: (@MainActor (HUDWindowActions) throws -> AnyView)? = nil,
        agent: (@MainActor (Binding<Bool>, AgentWindowActions) throws -> AnyView)? = nil,
        meetingPrompt: (@MainActor (DetectedMeeting) throws -> AnyView)? = nil
    ) {
        self.main = main
        self.hud = hud
        self.agent = agent
        self.meetingPrompt = meetingPrompt
    }
}

@MainActor
@Observable
private final class AgentWindowState {
    var transcriptVisible: Bool

    init(transcriptVisible: Bool) {
        self.transcriptVisible = transcriptVisible
    }
}

/// Owns Arco's native AppKit windows. Hidden capture surfaces remain
/// strongly owned and are reused for the entire process lifetime; this is the
/// native equivalent of overlay.rs's WindowServer leak prevention.
@MainActor
final class WindowCoordinator: NSObject, CaptureSurfaceCoordinating, NSWindowDelegate {
    static let agentTranscriptVisibilityKey = ArcoPreferenceKey.agentTranscriptVisible

    private(set) var mainWindow: NSWindow?
    private(set) var hudWindow: NSPanel?
    private(set) var agentWindow: NSPanel?
    private(set) var meetingPromptWindow: NSPanel?

    var canShowAgent: @MainActor () -> Bool = { false }
    var onHUDPresented: @MainActor () -> Void = {}
    var onHUDHidden: @MainActor () -> Void = {}
    var onAgentFocused: @MainActor () -> Void = {}
    var onMainWindowHidden: @MainActor () -> Void = {}
    var onSurfaceError: @MainActor (Error) -> Void = { _ in }

    private var factories: WindowContentFactories
    private let defaults: UserDefaults
    private let agentState: AgentWindowState
    private var keyEventMonitor: Any?

    init(
        factories: WindowContentFactories = WindowContentFactories(),
        defaults: UserDefaults = .standard
    ) {
        self.factories = factories
        self.defaults = defaults
        let transcriptVisible: Bool
        if defaults.object(forKey: Self.agentTranscriptVisibilityKey) == nil {
            transcriptVisible = true
        } else {
            transcriptVisible = defaults.bool(
                forKey: Self.agentTranscriptVisibilityKey
            )
        }
        agentState = AgentWindowState(transcriptVisible: transcriptVisible)
        super.init()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleOverlayKeyEvent(event)
        }
    }

    isolated deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    func install(_ factories: WindowContentFactories) {
        self.factories = factories
    }

    @discardableResult
    func showMainWindow() throws -> NSWindow {
        NSApp.setActivationPolicy(.regular)
        let window: NSWindow
        if let mainWindow {
            window = mainWindow
        } else {
            guard let factory = factories.main else {
                throw WindowCoordinatorError.contentNotInstalled("main")
            }
            let content = try factory()
            let created = NSWindow(
                contentRect: CGRect(origin: .zero, size: ArcoWindowMetrics.mainSize),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable,
                    .fullSizeContentView,
                ],
                backing: .buffered,
                defer: false
            )
            created.title = "Arco"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.titlebarSeparatorStyle = .none
            created.toolbarStyle = .unified
            created.contentMinSize = ArcoWindowMetrics.mainMinimumSize
            // The main surface paints every pixel. Marking this large window
            // transparent forces WindowServer to blend the whole desktop under
            // it continuously; transparency is reserved for the small overlays.
            created.isOpaque = true
            created.backgroundColor = NSColor(
                calibratedRed: 245 / 255,
                green: 248 / 255,
                blue: 250 / 255,
                alpha: 1
            )
            // ARC owns the window through `mainWindow`. AppKit releasing the
            // same window again on close can over-release it while the close
            // notification's autorelease pool is draining.
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.contentView = FirstMouseHostingView(rootView: content)
            created.center()
            if let miniaturize = created.standardWindowButton(.miniaturizeButton) {
                miniaturize.target = self
                miniaturize.action = #selector(minimizeMainWindowToMenuBar(_:))
                miniaturize.toolTip = "Keep Arco in the menu bar"
            }
            mainWindow = created
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        scheduleTrafficLightPositioning(in: window)
        return window
    }

    func focusMainWindow() throws {
        if mainWindow == nil {
            _ = try showMainWindow()
            return
        }
        guard let mainWindow else {
            throw WindowCoordinatorError.contentNotInstalled("main")
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
        scheduleTrafficLightPositioning(in: mainWindow)
    }

    // MARK: - CaptureSurfaceCoordinating

    func showCaptureHUD() throws {
        let hud = try ensureHUDWindow()
        let wasVisible = hud.isVisible
        guard let screen = preferredScreen(for: hud) else {
            throw WindowCoordinatorError.noAvailableDisplay
        }
        hud.setFrame(
            ArcoWindowPlacement.hudFrame(in: ScreenWorkArea(screen)),
            display: true
        )
        // Preserve show-without-focus behavior. The panel is still
        // focusable and accepts its Stop / Ask Arco controls on first click.
        if !wasVisible {
            onHUDPresented()
        }
        hud.orderFrontRegardless()
    }

    func releaseCaptureSurfaces() {
        onHUDHidden()
        hudWindow?.orderOut(nil)
        agentWindow?.orderOut(nil)
    }

    // MARK: - Agent overlay

    @discardableResult
    func toggleAgent() throws -> Bool {
        guard canShowAgent() else {
            throw WindowCoordinatorError.agentUnavailable
        }
        if agentWindow?.isVisible == true {
            hideAgent()
            return false
        }

        let existed = agentWindow != nil
        let agent = try ensureAgentWindow()
        guard let screen = agent.screen ?? preferredScreen(for: agent) else {
            throw WindowCoordinatorError.noAvailableDisplay
        }
        synchronizeAgentFrame(
            agent,
            on: screen,
            preservingTopLeft: existed
        )

        NSApp.activate(ignoringOtherApps: true)
        agent.makeKeyAndOrderFront(nil)
        return true
    }

    func hideAgent() {
        agentWindow?.orderOut(nil)
    }

    // MARK: - Meeting prompt

    func showMeetingPrompt(_ meeting: DetectedMeeting) throws {
        hideMeetingPrompt()
        guard let factory = factories.meetingPrompt else {
            throw WindowCoordinatorError.contentNotInstalled("meeting prompt")
        }
        let content = try factory(meeting)
        let meetingPrompt = OverlayPanel(
            contentRect: CGRect(origin: .zero, size: ArcoWindowMetrics.meetingPromptSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        meetingPrompt.title = "Arco Meeting"
        configureOverlay(meetingPrompt, kind: .meetingPrompt)
        meetingPrompt.isMovableByWindowBackground = true
        meetingPrompt.contentMinSize = ArcoWindowMetrics.meetingPromptSize
        meetingPrompt.contentMaxSize = ArcoWindowMetrics.meetingPromptSize
        meetingPrompt.contentView = FirstMouseHostingView(
            rootView: AnyView(
                SwiftUIOverlayGlassSurface(kind: .meetingPrompt) { content }
            )
        )
        guard let screen = preferredScreen(for: meetingPrompt) else {
            meetingPrompt.contentView = nil
            meetingPrompt.close()
            throw WindowCoordinatorError.noAvailableDisplay
        }
        meetingPrompt.setFrame(
            ArcoWindowPlacement.meetingPromptFrame(in: ScreenWorkArea(screen)),
            display: true
        )
        meetingPromptWindow = meetingPrompt
        meetingPrompt.orderFrontRegardless()
    }

    func hideMeetingPrompt() {
        guard let meetingPrompt = meetingPromptWindow else { return }
        meetingPromptWindow = nil
        meetingPrompt.delegate = nil
        meetingPrompt.orderOut(nil)
        meetingPrompt.contentView = nil
        meetingPrompt.close()
    }

    func setAgentTranscriptVisible(_ visible: Bool) {
        agentState.transcriptVisible = visible
        defaults.set(visible, forKey: Self.agentTranscriptVisibilityKey)
        guard let agentWindow else { return }
        guard let screen = agentWindow.screen ?? preferredScreen(for: agentWindow) else {
            onSurfaceError(WindowCoordinatorError.noAvailableDisplay)
            return
        }

        synchronizeAgentFrame(
            agentWindow,
            on: screen,
            preservingTopLeft: true
        )
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === hudWindow {
            onHUDHidden()
            sender.orderOut(nil)
            return false
        }
        if sender === agentWindow {
            sender.orderOut(nil)
            return false
        }
        if sender === meetingPromptWindow {
            meetingPromptWindow = nil
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            mainWindow = nil
            onMainWindowHidden()
            NSApp.setActivationPolicy(.accessory)
        } else if window === meetingPromptWindow {
            meetingPromptWindow = nil
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            scheduleTrafficLightPositioning(in: window)
        } else if window === agentWindow {
            onAgentFocused()
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow,
              let mainWindow else { return }
        positionTrafficLights(in: mainWindow)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow,
              let mainWindow else { return }
        scheduleTrafficLightPositioning(in: mainWindow)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow,
              let mainWindow else { return }
        scheduleTrafficLightPositioning(in: mainWindow)
    }

    // MARK: - Window creation

    private func ensureHUDWindow() throws -> NSPanel {
        if let hudWindow { return hudWindow }
        guard let factory = factories.hud else {
            throw WindowCoordinatorError.contentNotInstalled("recording HUD")
        }
        let actions = HUDWindowActions(toggleAgent: { [weak self] in
            guard let self else {
                throw WindowCoordinatorError.contentNotInstalled("agent")
            }
            return try self.toggleAgent()
        })
        let content = try factory(actions)
        let panel = OverlayPanel(
            contentRect: CGRect(origin: .zero, size: ArcoWindowMetrics.hudSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Arco Recording"
        configureOverlay(panel, kind: .hud)
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = ArcoWindowMetrics.hudSize
        panel.contentMaxSize = ArcoWindowMetrics.hudSize
        panel.contentView = FirstMouseHostingView(
            rootView: AnyView(
                SwiftUIOverlayGlassSurface(kind: .hud) { content }
            )
        )
        hudWindow = panel
        return panel
    }

    private func ensureAgentWindow() throws -> NSPanel {
        if let agentWindow { return agentWindow }
        guard let factory = factories.agent else {
            throw WindowCoordinatorError.contentNotInstalled("agent")
        }
        let state = agentState
        let visibility = Binding(
            get: { state.transcriptVisible },
            set: { [weak self] visible in
                self?.setAgentTranscriptVisible(visible)
            }
        )
        let actions = AgentWindowActions(
            hide: { [weak self] in self?.hideAgent() },
            focusMain: { [weak self] in
                guard let self else {
                    throw WindowCoordinatorError.contentNotInstalled("main")
                }
                try self.focusMainWindow()
            }
        )
        let content = try factory(visibility, actions)
        let initialSize = agentState.transcriptVisible
            ? ArcoWindowMetrics.agentSize
            : ArcoWindowMetrics.collapsedAgentSize
        let panel = OverlayPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Ask Arco"
        configureOverlay(panel, kind: .agent)
        panel.contentMinSize = CGSize(width: 432, height: 500)
        panel.contentMaxSize = ArcoWindowMetrics.agentMaximumSize
        panel.contentView = FirstMouseHostingView(
            rootView: AnyView(
                SwiftUIOverlayGlassSurface(kind: .agent) { content }
            )
        )
        agentWindow = panel
        return panel
    }

    private func configureOverlay(_ panel: NSPanel, kind: ArcoOverlayKind) {
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.floating.rawValue
                + (kind == .agent ? 0 : 1)
        )
        panel.animationBehavior = .none
    }

    private func synchronizeAgentFrame(
        _ agent: NSPanel,
        on screen: NSScreen,
        preservingTopLeft: Bool
    ) {
        let requested = agentState.transcriptVisible
            ? ArcoWindowMetrics.agentSize
            : ArcoWindowMetrics.collapsedAgentSize
        let area = ScreenWorkArea(screen)
        let fitted = ArcoWindowPlacement.fittedAgentSize(
            in: area,
            requested: requested
        )
        let frame = preservingTopLeft
            ? ArcoWindowPlacement.resizingPreservingTopLeft(
                agent.frame,
                to: fitted
            )
            : ArcoWindowPlacement.agentFrame(
                in: area,
                requested: requested
            )
        configureAgentMinimumSize(agent, fitted: fitted)
        agent.setFrame(
            frame,
            display: agent.isVisible,
            animate: false
        )
    }

    private func configureAgentMinimumSize(_ agent: NSPanel, fitted: CGSize) {
        agent.contentMinSize = CGSize(
            width: min(432, fitted.width),
            height: min(500, fitted.height)
        )
    }

    private func preferredScreen(for surface: NSWindow?) -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let underPointer = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underPointer
        }
        if let screen = mainWindow?.screen { return screen }
        if let screen = surface?.screen { return screen }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func handleOverlayKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let agentWindow,
              agentWindow.isVisible,
              event.window === agentWindow else { return event }
        let key = event.charactersIgnoringModifiers?.lowercased()
        let closeShortcut = key == "w"
            && !event.modifierFlags.intersection([.command, .control]).isEmpty
        if event.keyCode == 53 || closeShortcut {
            hideAgent()
            return nil
        }
        return event
    }

    @objc private func minimizeMainWindowToMenuBar(_ sender: Any?) {
        mainWindow?.close()
    }

    /// SwiftUI's first hosting-view layout restores AppKit's default 32-point
    /// titlebar after `makeKeyAndOrderFront`. Apply the source geometry now and
    /// once more on the next main-loop turn, after that layout has settled.
    private func scheduleTrafficLightPositioning(in window: NSWindow) {
        positionTrafficLights(in: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.mainWindow else { return }
            self.positionTrafficLights(in: window)
        }
    }

    /// Mirrors tao/wry's `trafficLightPosition: { x: 27, y: 26 }` exactly.
    private func positionTrafficLights(in window: NSWindow) {
        // Flush any pending NSThemeFrame / NSTitlebarContainerView layout
        // before overriding the titlebar frame, otherwise the pending layout
        // can immediately restore the system default vertical position.
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard
            let close = window.standardWindowButton(.closeButton),
            let miniaturize = window.standardWindowButton(.miniaturizeButton),
            let titlebarContainer = close.superview?.superview
        else { return }

        let closeFrame = close.frame
        titlebarContainer.frame = ArcoWindowChromeGeometry.titlebarContainerFrame(
            current: titlebarContainer.frame,
            windowHeight: window.frame.height,
            closeButtonFrame: closeFrame
        )

        let spacing = miniaturize.frame.minX - closeFrame.minX
        let buttons = [
            close,
            miniaturize,
            window.standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(
                ArcoWindowChromeGeometry.trafficLightOrigin(
                    current: button.frame.origin,
                    index: index,
                    spacing: spacing
                )
            )
        }
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
