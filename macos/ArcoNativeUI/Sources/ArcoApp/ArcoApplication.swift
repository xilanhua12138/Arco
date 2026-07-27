import AppKit
import ArcoNativeUI
import SwiftUI

@main
struct ArcoApplication: App {
    @NSApplicationDelegateAdaptor(ArcoApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {}
            }
    }
}

@MainActor
private final class ArcoApplicationDelegate: NSObject, NSApplicationDelegate {
    private var runtime: NativeApplicationRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ArcoProcessSignalPolicy.install()
        NSApp.setActivationPolicy(.regular)
        do {
            let runtime = try NativeApplicationRuntime()
            self.runtime = runtime
            try runtime.start()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Arco could not start"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.shutdown()
        runtime = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        do {
            try runtime?.windowCoordinator.focusMainWindow()
        } catch {
            runtime?.shellController.presentInterfaceError(error.localizedDescription)
        }
        return true
    }
}

@MainActor
private final class NativeApplicationBridge {
    weak var shellController: ArcoAppShellController?
    weak var shortcutController: GlobalShortcutController?
    weak var localization: ArcoLocalization?

    private var shortcutBeforeRecording: ListeningShortcut?
    private var recordingShortcut = false

    func handleGlobalShortcut() {
        guard let shellController else { return }
        Task { @MainActor in await shellController.handleGlobalListeningShortcut() }
    }

    func replaceShortcut(_ shortcut: ListeningShortcut?) async -> Bool {
        guard let shortcutController else { return false }
        do {
            try shortcutController.replace(with: shortcut)
            shortcutBeforeRecording = nil
            recordingShortcut = false
            return true
        } catch {
            shellController?.presentShortcutError(error.localizedDescription)
            return false
        }
    }

    func beginShortcutRecording() async -> Bool {
        guard let shortcutController else { return false }
        if recordingShortcut { return true }
        do {
            shortcutBeforeRecording = try shortcutController.beginRecording()
            recordingShortcut = true
            return true
        } catch {
            shellController?.presentShortcutError(error.localizedDescription)
            return false
        }
    }

    func cancelShortcutRecording() async {
        guard recordingShortcut, let shortcutController else { return }
        do {
            try shortcutController.register(shortcutBeforeRecording)
        } catch {
            shellController?.presentShortcutError(error.localizedDescription)
        }
        shortcutBeforeRecording = nil
        recordingShortcut = false
    }

    func setLocale(_ locale: AppLocale) {
        localization?.setLocale(locale)
    }

    func relaunch() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            shellController?.presentInterfaceError(error.localizedDescription)
        }
    }
}

@MainActor
private final class NativeApplicationRuntime {
    let preferences: ArcoPreferences
    let localization: ArcoLocalization
    let backend: RustBackendTransport
    let windowCoordinator: WindowCoordinator
    let store: ArcoStore
    let shellController: ArcoAppShellController

    private let bridge: NativeApplicationBridge
    private let shortcutController: GlobalShortcutController
    private let recordingHUDModel: RecordingHUDModel
    private let agentOverlayModel: AgentOverlayModel
    private var migrationError: String?

    init() throws {
        let preferenceStore = UserDefaultsKeyValueStore()
        do {
            _ = try LegacyWebKitPreferencesImporter(store: preferenceStore).migrateIfNeeded()
        } catch {
            migrationError = error.localizedDescription
        }

        let preferences = ArcoPreferences(store: preferenceStore)
        let localization = ArcoLocalization(preferences: preferences)
        let backend = try RustBackendTransport.create(configuration: .bundled)
        let windowCoordinator = WindowCoordinator()
        let translate: ArcoTranslate = { [weak localization] key, parameters in
            localization?.text(key, parameters: parameters)
                ?? ArcoTranslations.english(key, parameters)
        }
        let store = ArcoStore(
            backend: backend,
            captureSurfaces: windowCoordinator,
            translate: translate,
            loadProviderConfiguration: { preferences.loadProviderConfiguration() },
            loadGenerationSettings: { preferences.loadGenerationSettings() }
        )
        let bridge = NativeApplicationBridge()
        bridge.localization = localization
        let environment = ArcoAppEnvironment(
            changeListeningShortcut: { [weak bridge] shortcut in
                await bridge?.replaceShortcut(shortcut) ?? false
            },
            startListeningShortcutRecording: { [weak bridge] in
                await bridge?.beginShortcutRecording() ?? false
            },
            cancelListeningShortcutRecording: { [weak bridge] in
                await bridge?.cancelShortcutRecording()
            },
            localeChanged: { [weak bridge] locale in bridge?.setLocale(locale) },
            relaunch: { [weak bridge] in await bridge?.relaunch() }
        )
        let shellController = ArcoAppShellController(
            store: store,
            preferences: preferences,
            translate: translate,
            environment: environment
        )
        bridge.shellController = shellController
        let shortcutController = GlobalShortcutController { [weak bridge] in
            bridge?.handleGlobalShortcut()
        }
        bridge.shortcutController = shortcutController

        let recordingHUDModel = RecordingHUDModel(
            readCapture: {
                try await backend.call("capture_status")
            },
            stopCapture: {
                guard store.capture.phase == .recording else {
                    throw BackendTransportError.backend("No capture is running")
                }
                guard let state = await store.toggleCapture() else {
                    throw BackendTransportError.backend(
                        store.error ?? "Capture could not be stopped"
                    )
                }
                return state
            },
            onStopped: { [weak windowCoordinator] in
                windowCoordinator?.releaseCaptureSurfaces()
            }
        )

        let agentOverlayModel = AgentOverlayModel(
            loadActiveSnapshot: {
                let capture: CaptureState = try await backend.call("capture_status")
                let runtimes: [RuntimeStatus] = try await backend.call("runtime_status")
                var meeting: MeetingDetail?
                var replies: [AgentTurn] = []
                var attachments: [MeetingAttachment] = []
                if let meetingID = capture.activeMeetingId {
                    meeting = try await backend.call(
                        "read_meeting",
                        arguments: ["id": .string(meetingID)]
                    )
                    replies = try await backend.call(
                        "list_agent_turns",
                        arguments: ["meetingId": .string(meetingID)]
                    )
                    attachments = (try? await backend.call(
                        "list_attachments",
                        arguments: ["meetingId": .string(meetingID)]
                    )) ?? []
                }
                return AgentOverlaySnapshot(
                    meeting: meeting,
                    capture: capture,
                    replies: replies,
                    runtimes: runtimes,
                    providerConfiguration: shellController.providerConfiguration,
                    running: store.agentRunning,
                    streamingTurn: store.agentStreamingTurn,
                    loading: false,
                    workspace: shellController.agentWorkspace,
                    attachments: attachments
                )
            },
            runAsk: { request in
                await store.askAgent(AskAgentInput(
                    provider: request.provider,
                    usedFallback: request.usedFallback,
                    question: request.question,
                    agentPrompt: request.agentPrompt,
                    meetingId: request.meetingID,
                    workspace: request.workspace,
                    contextScope: request.contextScope.rawValue
                ))
            },
            toggleSaved: { meetingID, turnID, saved in
                await store.setAgentTurnSaved(
                    meetingId: meetingID,
                    turnId: turnID,
                    saved: saved
                )
            },
            chooseWorkspace: { await shellController.chooseWorkspace() },
            attachDocument: { meetingID in
                await shellController.attachDocument(to: meetingID)
            },
            removeAttachment: { meetingID, attachmentID in
                await shellController.removeAttachment(attachmentID, from: meetingID)
            }
        )

        self.preferences = preferences
        self.localization = localization
        self.backend = backend
        self.windowCoordinator = windowCoordinator
        self.store = store
        self.shellController = shellController
        self.bridge = bridge
        self.shortcutController = shortcutController
        self.recordingHUDModel = recordingHUDModel
        self.agentOverlayModel = agentOverlayModel

        windowCoordinator.canShowAgent = { [weak store] in
            store?.capture.phase == .recording && store?.capture.activeMeetingId != nil
        }
        windowCoordinator.onHUDPresented = { [weak recordingHUDModel] in
            recordingHUDModel?.prepareForCaptureStart()
            recordingHUDModel?.startMonitoring()
        }
        windowCoordinator.onHUDHidden = { [weak recordingHUDModel] in
            recordingHUDModel?.stopMonitoring()
        }
        windowCoordinator.onAgentFocused = { [weak agentOverlayModel] in
            Task { @MainActor in await agentOverlayModel?.refresh() }
        }
        windowCoordinator.onSurfaceError = { [weak shellController] error in
            shellController?.presentInterfaceError(error.localizedDescription)
        }
        windowCoordinator.install(WindowContentFactories(
            main: { [weak shellController] in
                guard let shellController else {
                    throw WindowCoordinatorError.contentNotInstalled("main")
                }
                return AnyView(ArcoMainShellView(
                    controller: shellController,
                    translate: translate
                ))
            },
            hud: { [weak recordingHUDModel, weak shellController] actions in
                guard let recordingHUDModel, let shellController else {
                    throw WindowCoordinatorError.contentNotInstalled("recording HUD")
                }
                return AnyView(RecordingHUDView(
                    model: recordingHUDModel,
                    translate: translate,
                    onToggleAgent: actions.toggleAgent,
                    onError: { error in
                        shellController.presentInterfaceError(error.localizedDescription)
                    }
                ))
            },
            agent: { [weak agentOverlayModel, weak shellController, weak store] visibility, actions in
                guard let agentOverlayModel, let shellController, let store else {
                    throw WindowCoordinatorError.contentNotInstalled("agent")
                }
                return AnyView(AgentOverlayHostView(
                    model: agentOverlayModel,
                    store: store,
                    shellController: shellController,
                    transcriptVisible: visibility,
                    translate: translate,
                    actions: actions
                ))
            }
        ))
    }

    func start() throws {
        do {
            try shortcutController.register(preferences.loadListeningShortcut())
        } catch {
            shellController.presentInterfaceError(error.localizedDescription)
        }
        if let migrationError {
            shellController.presentInterfaceError(migrationError)
        }
        _ = try windowCoordinator.showMainWindow()
    }

    func shutdown() {
        store.dispose()
        windowCoordinator.releaseCaptureSurfaces()
        try? shortcutController.unregister()
        backend.shutdown()
    }
}

private struct AgentOverlayHostView: View {
    @Bindable var model: AgentOverlayModel
    @Bindable var store: ArcoStore
    @ObservedObject var shellController: ArcoAppShellController
    @Binding var transcriptVisible: Bool

    let translate: ArcoTranslate
    let actions: AgentWindowActions

    var body: some View {
        AgentOverlaySurfaceView(
            model: model,
            transcriptVisible: $transcriptVisible,
            translate: translate,
            onHide: actions.hide,
            onFocusMain: actions.focusMain,
            onError: { error in
                shellController.presentInterfaceError(error.localizedDescription)
            }
        )
        .onChange(of: store.agentStreamingTurn) { _, turn in
            model.applyStreamingTurn(turn)
        }
        .onChange(of: store.agentRunning) { _, running in
            model.applyRunning(running)
        }
        .onChange(of: store.agentTurnsByMeeting) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: store.capture) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: shellController.providerConfiguration) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: shellController.agentWorkspace) { _, _ in
            Task { await model.refresh() }
        }
    }
}
