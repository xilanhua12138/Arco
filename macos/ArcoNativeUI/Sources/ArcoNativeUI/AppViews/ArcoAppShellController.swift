import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct ArcoAppEnvironment {
    public var chooseDirectory: (_ title: String) async -> String?
    public var chooseWorkspace: (_ title: String) async -> String?
    public var chooseAttachment: (_ title: String) async -> (name: String, text: String)?
    public var fetchLatestRelease: () async throws -> ArcoReleaseInfo
    public var downloadUpdate: (ArcoReleaseInfo, @Sendable (Double) -> Void) async throws -> URL
    public var installUpdate: (URL) async throws -> Void
    public var copyText: (_ text: String) async throws -> Void
    public var openURL: (_ url: URL) async throws -> Void
    public var changeListeningShortcut: (_ shortcut: ListeningShortcut?) async -> Bool
    public var startListeningShortcutRecording: () async -> Bool
    public var cancelListeningShortcutRecording: () async -> Void
    public var startGPTLiveSession: (_ request: GPTLiveSessionRequest) async throws -> any GPTLiveSessionHandle
    public var stopPendingGPTLiveSession: () async -> Void
    public var loadGPTLiveCredential: () async throws -> GPTLiveCredentialStatus
    public var connectGPTLiveCredential: () async throws -> GPTLiveCredentialStatus
    public var disconnectGPTLiveCredential: () async throws -> GPTLiveCredentialStatus
    public var localeChanged: (_ locale: AppLocale) -> Void
    public var relaunch: () async -> Void
    public var requestMeetingAccess: () -> Void
    public var resumeMeetingPrompts: () -> Void

    public init(
        chooseDirectory: @escaping (_ title: String) async -> String? = ArcoAppEnvironment.nativeDirectoryPicker,
        chooseWorkspace: @escaping (_ title: String) async -> String? = ArcoAppEnvironment.nativeDirectoryPicker,
        chooseAttachment: @escaping (_ title: String) async -> (name: String, text: String)? = ArcoAppEnvironment.nativeAttachmentPicker,
        fetchLatestRelease: @escaping () async throws -> ArcoReleaseInfo = ArcoAppEnvironment.nativeFetchLatestRelease,
        downloadUpdate: @escaping (ArcoReleaseInfo, @Sendable (Double) -> Void) async throws -> URL = ArcoAppEnvironment.nativeDownloadUpdate,
        installUpdate: @escaping (URL) async throws -> Void = ArcoAppEnvironment.nativeInstallUpdate,
        copyText: @escaping (_ text: String) async throws -> Void = ArcoAppEnvironment.nativeCopy,
        openURL: @escaping (_ url: URL) async throws -> Void = ArcoAppEnvironment.nativeOpenURL,
        changeListeningShortcut: @escaping (_ shortcut: ListeningShortcut?) async -> Bool = { _ in true },
        startListeningShortcutRecording: @escaping () async -> Bool = { true },
        cancelListeningShortcutRecording: @escaping () async -> Void = {},
        startGPTLiveSession: @escaping (_ request: GPTLiveSessionRequest) async throws -> any GPTLiveSessionHandle = { _ in
            throw GPTLiveSessionLaunchError.unavailable
        },
        stopPendingGPTLiveSession: @escaping () async -> Void = {},
        loadGPTLiveCredential: @escaping () async throws -> GPTLiveCredentialStatus = { .missing },
        connectGPTLiveCredential: @escaping () async throws -> GPTLiveCredentialStatus = { .missing },
        disconnectGPTLiveCredential: @escaping () async throws -> GPTLiveCredentialStatus = { .missing },
        localeChanged: @escaping (_ locale: AppLocale) -> Void = { _ in },
        relaunch: @escaping () async -> Void = {},
        requestMeetingAccess: @escaping () -> Void = {},
        resumeMeetingPrompts: @escaping () -> Void = {}
    ) {
        self.chooseDirectory = chooseDirectory
        self.chooseWorkspace = chooseWorkspace
        self.chooseAttachment = chooseAttachment
        self.fetchLatestRelease = fetchLatestRelease
        self.downloadUpdate = downloadUpdate
        self.installUpdate = installUpdate
        self.copyText = copyText
        self.openURL = openURL
        self.changeListeningShortcut = changeListeningShortcut
        self.startListeningShortcutRecording = startListeningShortcutRecording
        self.cancelListeningShortcutRecording = cancelListeningShortcutRecording
        self.startGPTLiveSession = startGPTLiveSession
        self.stopPendingGPTLiveSession = stopPendingGPTLiveSession
        self.loadGPTLiveCredential = loadGPTLiveCredential
        self.connectGPTLiveCredential = connectGPTLiveCredential
        self.disconnectGPTLiveCredential = disconnectGPTLiveCredential
        self.localeChanged = localeChanged
        self.relaunch = relaunch
        self.requestMeetingAccess = requestMeetingAccess
        self.resumeMeetingPrompts = resumeMeetingPrompts
    }

    public static func nativeDirectoryPicker(_ title: String) async -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Picks a single reference document and returns its extracted plain text.
    /// The Agent never receives file-system access; only the extracted text is
    /// stored and inlined into the prompt.
    public static func nativeAttachmentPicker(_ title: String) async -> (name: String, text: String)? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.pdf, .plainText, .text]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let name = url.lastPathComponent
        let text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (name, text)
    }

    public static func nativeCopy(_ text: String) async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public static func nativeOpenURL(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }
}

@MainActor
public final class ArcoAppShellController: ObservableObject {
    @Published public var page: AppRoute = .current
    @Published public private(set) var query = ""
    @Published public private(set) var notesQuery = ""
    @Published public private(set) var audioMode: AudioMode
    @Published public private(set) var providerConfiguration: ProviderConfiguration
    @Published public private(set) var generationSettings: GenerationSettings
    @Published public private(set) var transcriptionConfiguration: TranscriptionConfiguration
    @Published public private(set) var listeningShortcut: ListeningShortcut?
    @Published public private(set) var locale: AppLocale
    @Published public private(set) var agentWorkspace: String?
    @Published public private(set) var settingsOpen = false
    @Published public private(set) var settingsPage: SettingsPage = .general
    public private(set) var settingsFocusRestoreGeneration = 0
    @Published public private(set) var providerSetupOpen: Bool
    @Published public private(set) var editingProviders = false
    @Published public private(set) var shortcutTestCount = 0
    @Published public private(set) var interfaceError: String?
    @Published public private(set) var shortcutError: String?
    @Published public private(set) var meetingAccessAuthorized = false
    @Published public private(set) var automaticMeetingPromptsEnabled: Bool
    @Published public private(set) var gptLiveBetaEnabled: Bool
    @Published public private(set) var gptLiveCredential: GPTLiveCredentialStatus = .checking

    public let store: ArcoStore
    public let preferences: ArcoPreferences
    public let environment: ArcoAppEnvironment
    public let updateManager: UpdateManager
    public let gptLiveSession: GPTLiveSessionModel
    public lazy var shortcutViewModel: ShortcutRecorderViewModel = ShortcutRecorderViewModel(
        value: listeningShortcut,
        onChange: { [weak self] shortcut in
            await self?.changeShortcut(shortcut) ?? false
        },
        onStartRecording: environment.startListeningShortcutRecording,
        onCancelRecording: environment.cancelListeningShortcutRecording
    )
    public var topBarViewModel: TopBarViewModel {
        if let topBarViewModelStorage { return topBarViewModelStorage }
        let model = TopBarViewModel { [weak store] meetingID, title in
            await store?.renameMeeting(meetingID, title: title) ?? false
        }
        topBarViewModelStorage = model
        return model
    }

    private let translate: ArcoTranslate
    private var meetingSearchTask: Task<Void, Never>?
    private var notesSearchTask: Task<Void, Never>?
    private var notesLoadTask: Task<Void, Never>?
    private var pendingNotesQuery: String?
    private var openedCompletedMeetingID: String?
    private var topBarViewModelStorage: TopBarViewModel?
    private var notesViewModelStorage: NotesPageViewModel?
    private var settingsViewModelStorage: SettingsSheetViewModel?
    private var providerViewModelStorage: ProviderSetupViewModel?
    private var onboardingViewModelStorage: OnboardingViewModel?
    private var settingsGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    public init(
        store: ArcoStore,
        preferences: ArcoPreferences,
        translate: @escaping ArcoTranslate,
        environment: ArcoAppEnvironment = ArcoAppEnvironment()
    ) {
        self.store = store
        self.preferences = preferences
        self.translate = translate
        self.environment = environment
        gptLiveSession = GPTLiveSessionModel(
            start: environment.startGPTLiveSession,
            stopPending: environment.stopPendingGPTLiveSession
        )
        updateManager = UpdateManager(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            dependencies: UpdateManager.Dependencies(
                fetchLatestRelease: environment.fetchLatestRelease,
                downloadUpdate: environment.downloadUpdate,
                installUpdate: environment.installUpdate
            )
        )
        audioMode = preferences.loadAudioMode()
        let initialProviderConfiguration = preferences.loadProviderConfiguration()
        providerConfiguration = initialProviderConfiguration
        generationSettings = preferences.loadGenerationSettings()
        transcriptionConfiguration = preferences.loadTranscriptionConfiguration()
        listeningShortcut = preferences.loadListeningShortcut()
        automaticMeetingPromptsEnabled = preferences
            .loadMeetingPromptPreference()
            .automaticPromptsEnabled
        gptLiveBetaEnabled = preferences.loadGPTLiveBetaEnabled()
        locale = preferences.loadLocale()
        agentWorkspace = preferences.loadAgentWorkspace()
        let onboarding = preferences.loadOnboardingState()
        providerSetupOpen = !initialProviderConfiguration.setupComplete && !onboarding.completed

        updateManager.$state
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.updateSettingsViewModel()
            }
            .store(in: &cancellables)
        gptLiveSession.$status
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    deinit {
        meetingSearchTask?.cancel()
        notesSearchTask?.cancel()
        notesLoadTask?.cancel()
    }

    public var audioModeLocked: Bool {
        [.starting, .recording, .stopping].contains(store.capture.phase)
    }

    public var displayedAudioMode: AudioMode {
        audioModeLocked ? store.capture.mode ?? audioMode : audioMode
    }

    public var reviewingWhileRecording: Bool {
        store.capture.phase == .recording
            && store.capture.activeMeetingId != nil
            && store.meeting?.summary.id != store.capture.activeMeetingId
    }

    public var currentMeeting: MeetingDetail? {
        guard store.capture.phase == .recording,
              let activeID = store.capture.activeMeetingId,
              store.meeting?.summary.id == activeID
        else { return nil }
        return store.meeting
    }

    public var providerRoute: ProviderRoute {
        .resolve(config: providerConfiguration, runtimes: store.runtimes)
    }

    public func initialize() async {
        let setupTask: Task<[TranscriptionModelStatus]?, Never>? = if providerSetupOpen {
            Task { @MainActor [weak store] in try? await store?.refreshSetupStatus() }
        } else {
            nil
        }
        await store.initialize()
        _ = await setupTask?.value
        gptLiveCredential = (try? await environment.loadGPTLiveCredential()) ?? GPTLiveCredentialStatus(
            phase: .failed,
            message: translate("settings.gptLiveStatusUnavailable", [:])
        )
        updateDependentViewModels()
        Task { [weak self] in await self?.checkForUpdates() }
    }

    public var updateAvailable: Bool {
        updateManager.state.availableRelease != nil
    }

    public func checkForUpdates() async {
        await updateManager.checkForUpdates()
    }

    public func installUpdate() async {
        await updateManager.installUpdate()
    }

    public func setQuery(_ value: String) {
        query = value
        meetingSearchTask?.cancel()
        meetingSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.query == value else { return }
            await self.store.refreshMeetings(value)
        }
    }

    public func setNotesQuery(_ value: String) {
        notesQuery = value
        notesViewModelStorage?.update(
            notes: store.savedNotes,
            meetings: store.meetings,
            query: value,
            loading: store.notesLoading
        )
        guard page == .notes else { return }
        notesLoadTask?.cancel()
        notesLoadTask = nil
        pendingNotesQuery = nil
        notesSearchTask?.cancel()
        notesSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  let self,
                  self.page == .notes,
                  self.notesQuery == value
            else { return }
            _ = await self.store.refreshSavedNotes(value)
        }
    }

    /// Mirrors React navigation: commit the route in the initiating event turn,
    /// then let route-owned data refresh without delaying click feedback.
    public func requestPage(_ next: AppRoute) {
        switch next {
        case .notes:
            dismissSettings()
            transition(to: .notes)
            startNotesRefreshIfNeeded()
        case .history, .review:
            dismissSettings()
            transition(to: next)
        case .current:
            Task { @MainActor [weak self] in await self?.showPage(.current) }
        }
    }

    public func showPage(_ next: AppRoute) async {
        dismissSettings()
        if next == .notes {
            transition(to: .notes)
            startNotesRefreshIfNeeded()
            await notesLoadTask?.value
            return
        }
        if next == .current,
           store.capture.phase == .recording,
           let activeID = store.capture.activeMeetingId,
           store.selectedMeetingId != activeID {
            guard await store.selectMeeting(activeID) else { return }
        }
        if next == .current, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearMeetingQuery()
            await store.refreshMeetings("")
        }
        transition(to: next)
    }

    public func selectMeeting(_ id: String) async {
        guard await store.selectMeeting(id) else { return }
        transition(to: id == store.capture.activeMeetingId ? .current : .review)
    }

    public func toggleCapture(resumeMeetingID: String? = nil) async {
        guard !store.loading else { return }
        guard store.capture.phase != .stopping else { return }
        if store.capture.phase == .recording {
            await gptLiveSession.disconnect()
        }
        if store.capture.phase == .recording, page == .current {
            topBarViewModelStorage = nil
        }
        let next = await store.toggleCapture(
            mode: audioMode,
            transcription: transcriptionConfiguration,
            resumeMeetingId: resumeMeetingID
        )
        if next?.phase == .starting || next?.phase == .recording {
            transition(to: .current)
        }
    }

    public func captureCompletedMeetingChanged() {
        captureStateChanged(store.capture)
        if page == .current, store.capture.phase != .recording {
            topBarViewModelStorage = nil
        }
        guard let completed = store.completedMeetingId else {
            openedCompletedMeetingID = nil
            return
        }
        guard openedCompletedMeetingID != completed,
              store.capture.phase == .idle,
              store.selectedMeetingId == completed,
              store.meeting?.summary.id == completed
        else { return }
        openedCompletedMeetingID = completed
        dismissSettings()
        clearMeetingQuery()
        transition(to: .review)
    }

    /// Capture can stop from the main window, recording HUD, menu bar, or a
    /// backend event. GPT Live follows the shared capture state instead of any
    /// individual view lifecycle so none of those paths can leak a call.
    public func captureStateChanged(_ state: CaptureState) {
        guard state.phase != .recording,
              gptLiveSession.status.phase != .idle,
              gptLiveSession.status.phase != .disconnecting
        else { return }
        Task { @MainActor [weak self] in
            await self?.gptLiveSession.disconnect()
        }
    }

    public func openSettings(_ initialPage: SettingsPage = .general) {
        notesViewModelStorage?.formatOpen = false
        settingsGeneration += 1
        let generation = settingsGeneration
        settingsPage = initialPage
        settingsOpen = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            async let storage: StorageSettings? = self.store.loadStorageSettings()
            async let setup: [TranscriptionModelStatus]? = try? self.store.refreshSetupStatus()
            _ = await (storage, setup)
            guard self.settingsOpen, self.settingsGeneration == generation else { return }
            self.updateSettingsViewModel()
        }
    }

    public func closeSettings() {
        dismissSettings(restoringTriggerFocus: true)
    }

    public func closeSettingsWithoutRestoringFocus() {
        dismissSettings()
    }

    public func enterMenuBarMode() {
        meetingSearchTask?.cancel()
        meetingSearchTask = nil
        notesSearchTask?.cancel()
        notesSearchTask = nil
        notesLoadTask?.cancel()
        notesLoadTask = nil
        pendingNotesQuery = nil
        notesViewModelStorage?.teardown()
        notesViewModelStorage = nil
        topBarViewModelStorage = nil
        settingsViewModelStorage = nil
        providerViewModelStorage = nil
        onboardingViewModelStorage = nil
        settingsOpen = false
        store.releaseIdlePresentationCache()
    }

    public func updateMeetingAwareness(
        authorized: Bool,
        automaticPromptsEnabled: Bool
    ) {
        meetingAccessAuthorized = authorized
        automaticMeetingPromptsEnabled = automaticPromptsEnabled
        updateSettingsViewModel()
    }

    public func openProviderSetup() {
        notesViewModelStorage?.formatOpen = false
        dismissSettings()
        editingProviders = true
        providerSetupOpen = true
        providerViewModelStorage = nil
    }

    public func cancelProviderSetup() {
        Task { await shortcutViewModel.teardown() }
        providerSetupOpen = false
        editingProviders = false
        providerViewModelStorage = nil
    }

    public func dismissError() {
        interfaceError = nil
        store.dismissError()
        store.dismissStorageError()
    }

    public func presentInterfaceError(_ message: String) {
        interfaceError = message
    }

    public func presentShortcutError(_ message: String) {
        shortcutError = message
        updateSettingsViewModel()
    }

    public func changeAudioMode(_ mode: AudioMode) {
        guard !audioModeLocked else { return }
        audioMode = mode
        preferences.saveAudioMode(mode)
        updateSettingsViewModel()
    }

    public func changeTranscriptionConfiguration(_ configuration: TranscriptionConfiguration) {
        guard !audioModeLocked else { return }
        do {
            try preferences.saveTranscriptionConfiguration(configuration)
            transcriptionConfiguration = configuration
            updateSettingsViewModel()
        } catch { interfaceError = error.localizedDescription }
    }

    public func changeGenerationSettings(_ settings: GenerationSettings) {
        do {
            try preferences.saveGenerationSettings(settings)
            generationSettings = settings
            updateSettingsViewModel()
        } catch { interfaceError = error.localizedDescription }
    }

    public func changeGPTLiveBetaEnabled(_ enabled: Bool) {
        gptLiveBetaEnabled = enabled
        preferences.saveGPTLiveBetaEnabled(enabled)
        if !enabled, gptLiveSession.status.phase != .idle {
            Task { @MainActor [weak self] in await self?.gptLiveSession.disconnect() }
        }
        updateSettingsViewModel()
    }

    public func connectGPTLiveCredential() async throws -> GPTLiveCredentialStatus {
        if gptLiveSession.status.phase != .idle {
            await gptLiveSession.disconnect()
        }
        gptLiveCredential = GPTLiveCredentialStatus(phase: .connecting)
        updateSettingsViewModel()
        do {
            let status = try await environment.connectGPTLiveCredential()
            gptLiveCredential = status
            updateSettingsViewModel()
            return status
        } catch {
            gptLiveCredential = GPTLiveCredentialStatus(
                phase: .failed,
                message: error.localizedDescription
            )
            updateSettingsViewModel()
            throw error
        }
    }

    public func disconnectGPTLiveCredential() async throws -> GPTLiveCredentialStatus {
        if gptLiveSession.status.phase != .idle {
            await gptLiveSession.disconnect()
        }
        gptLiveCredential = .checking
        updateSettingsViewModel()
        do {
            let status = try await environment.disconnectGPTLiveCredential()
            gptLiveCredential = status
            updateSettingsViewModel()
            return status
        } catch {
            gptLiveCredential = GPTLiveCredentialStatus(
                phase: .failed,
                message: error.localizedDescription
            )
            updateSettingsViewModel()
            throw error
        }
    }

    public func toggleGPTLive() async {
        guard gptLiveBetaEnabled else {
            interfaceError = translate("agent.gptLiveEnableFirst", [:])
            return
        }
        guard gptLiveCredential.phase == .connected else {
            interfaceError = translate("agent.gptLiveConnectAccountFirst", [:])
            return
        }
        guard store.capture.phase == .recording,
              store.capture.activeMeetingId != nil,
              let transcriptPath = store.capture.transcriptPath ?? store.meeting?.summary.path
        else {
            interfaceError = translate("agent.gptLiveMeetingRequired", [:])
            return
        }
        let provider = ProviderRoute.resolve(
            config: providerConfiguration,
            runtimes: store.runtimes
        ).provider ?? providerConfiguration.primary ?? .codex
        await gptLiveSession.toggle(request: GPTLiveSessionRequest(
            mode: displayedAudioMode,
            transcriptPath: transcriptPath,
            provider: provider
        ))
    }

    public func changeLocale(_ rawValue: String) {
        guard let next = AppLocale(rawValue: rawValue) else { return }
        locale = next
        preferences.saveLocale(next)
        environment.localeChanged(next)
        updateSettingsViewModel()
    }

    public func changeShortcut(_ shortcut: ListeningShortcut?) async -> Bool {
        shortcutError = nil
        updateSettingsViewModel()
        guard await environment.changeListeningShortcut(shortcut) else {
            updateSettingsViewModel()
            return false
        }
        do {
            try preferences.saveListeningShortcut(shortcut)
            listeningShortcut = shortcut
            shortcutViewModel.updateExternalValue(shortcut)
            shortcutError = nil
            updateSettingsViewModel()
            return true
        } catch {
            shortcutError = error.localizedDescription
            updateSettingsViewModel()
            return false
        }
    }

    public func chooseWorkspace() async -> String? {
        guard let path = await environment.chooseWorkspace(translate("agent.chooseWorkspaceDialogTitle", [:])) else {
            return nil
        }
        preferences.saveAgentWorkspace(path)
        agentWorkspace = path
        return path
    }

    public func attachDocument(to meetingID: String) async -> Bool {
        guard let picked = await environment.chooseAttachment(
            translate("agent.attachDocumentDialogTitle", [:])
        ) else {
            return false
        }
        return await store.addAttachment(meetingId: meetingID, name: picked.name, text: picked.text)
    }

    public func removeAttachment(_ attachmentID: String, from meetingID: String) async {
        _ = await store.removeAttachment(meetingId: meetingID, attachmentId: attachmentID)
    }

    public func handleGlobalListeningShortcut() async {
        if providerSetupOpen && !editingProviders {
            shortcutTestCount += 1
            return
        }
        await toggleCapture()
    }

    public func updateDependentViewModels() {
        notesViewModelStorage?.update(
            notes: store.savedNotes,
            meetings: store.meetings,
            query: notesQuery,
            loading: store.notesLoading
        )
        onboardingViewModelStorage?.updateExternalSetupStatus(
            runtimes: store.runtimes,
            models: store.transcriptionModels,
            deepgramCredential: store.deepgramCredential,
            elevenLabsCredential: store.elevenLabsCredential,
            doubaoCredential: store.doubaoCredential
        )
        updateSettingsViewModel()
    }

    public func notesViewModel() -> NotesPageViewModel {
        if let notesViewModelStorage { return notesViewModelStorage }
        let model = NotesPageViewModel(
            notes: store.savedNotes,
            meetings: store.meetings,
            query: notesQuery,
            loading: store.notesLoading,
            onQueryChange: { [weak self] in self?.setNotesQuery($0) },
            onOpenMeeting: { [weak self] id in
                Task { @MainActor in await self?.selectMeeting(id) }
            },
            onSaveNote: { [weak store] draft in
                guard let meetingID = draft.meetingId else { return nil }
                return await store?.saveNote(SaveNoteInput(
                    id: draft.id,
                    meetingId: meetingID,
                    title: draft.title,
                    body: draft.body
                ))
            },
            onDeleteNote: { [weak store] id in await store?.deleteNote(id) ?? false }
        )
        notesViewModelStorage = model
        return model
    }

    public func settingsViewModel() -> SettingsSheetViewModel {
        if let settingsViewModelStorage {
            settingsViewModelStorage.updateExternalSnapshot(settingsSnapshot)
            return settingsViewModelStorage
        }
        shortcutViewModel.updateExternalValue(listeningShortcut)
        let model = SettingsSheetViewModel(
            snapshot: settingsSnapshot,
            initialPage: settingsPage,
            shortcutViewModel: shortcutViewModel,
            actions: settingsActions
        )
        settingsViewModelStorage = model
        return model
    }

    public func providerViewModel() -> ProviderSetupViewModel {
        if let providerViewModelStorage { return providerViewModelStorage }
        let model = ProviderSetupViewModel(
            mode: .provider,
            runtimes: store.runtimes,
            initialConfiguration: providerConfiguration,
            onRefresh: { [weak store] in await store?.refreshRuntimes() },
            onTest: { [weak store] provider in
                guard let store else { throw CancellationError() }
                return try await store.testProvider(provider)
            },
            onComplete: { [weak self] configuration in
                Task { await self?.shortcutViewModel.teardown() }
                self?.saveProviderConfiguration(configuration)
                self?.providerSetupOpen = false
                self?.editingProviders = false
            }
        )
        providerViewModelStorage = model
        return model
    }

    public func onboardingViewModel() -> OnboardingViewModel {
        if let onboardingViewModelStorage { return onboardingViewModelStorage }
        let model = OnboardingViewModel(
            runtimes: store.runtimes,
            transcriptionConfiguration: transcriptionConfiguration,
            transcriptionModels: store.transcriptionModels,
            deepgramCredential: store.deepgramCredential,
            elevenLabsCredential: store.elevenLabsCredential,
            doubaoCredential: store.doubaoCredential,
            listeningShortcut: listeningShortcut,
            shortcutTestCount: shortcutTestCount,
            restoredDraft: preferences.loadOnboardingDraft(),
            onRefreshRuntimes: { [weak store] in await store?.refreshRuntimes() },
            onTestProvider: { [weak store] provider in
                guard let store else { throw CancellationError() }
                return try await store.testProvider(provider)
            },
            onSaveDeepgramAPIKey: { [weak store] key in
                guard let store else { throw CancellationError() }
                return try await store.saveDeepgramAPIKey(key)
            },
            onSaveElevenLabsAPIKey: { [weak store] key in
                guard let store else { throw CancellationError() }
                return try await store.saveElevenLabsAPIKey(key)
            },
            onSaveDoubaoCredentials: { [weak store] appID, token in
                guard let store else { throw CancellationError() }
                return try await store.saveDoubaoCredentials(appId: appID, accessToken: token)
            },
            onPrepareTranscriptionModel: { [weak store] model in
                guard let store else { throw CancellationError() }
                return try await store.prepareTranscriptionModel(model)
            },
            onTestAudio: { [weak store] mode in
                guard let store else { throw CancellationError() }
                return try await store.testAudio(mode)
            },
            onRelaunch: environment.relaunch,
            saveDraft: { [weak self] draft in try? self?.preferences.saveOnboardingDraft(draft) },
            clearDraft: { [weak self] in self?.preferences.clearOnboardingDraft() },
            onComplete: { [weak self] result in
                guard let self else { return }
                self.saveProviderConfiguration(result.providerConfiguration)
                try self.preferences.saveTranscriptionConfiguration(result.transcriptionConfiguration)
                self.transcriptionConfiguration = result.transcriptionConfiguration
                self.audioMode = result.audioMode
                self.preferences.saveAudioMode(result.audioMode)
                _ = self.preferences.completeOnboarding(skipped: false)
                await self.shortcutViewModel.teardown()
                self.providerSetupOpen = false
                if result.startListening { await self.toggleCapture() }
            },
            onSkip: { [weak self] in
                guard let self else { return }
                Task { await self.shortcutViewModel.teardown() }
                _ = self.preferences.completeOnboarding(skipped: true)
                self.providerSetupOpen = false
            }
        )
        onboardingViewModelStorage = model
        return model
    }

    private var settingsSnapshot: SettingsSheetSnapshot {
        SettingsSheetSnapshot(
            isDesktop: true,
            locale: locale.rawValue,
            runtimes: store.runtimes,
            audioMode: displayedAudioMode,
            audioModeLocked: audioModeLocked,
            transcriptionConfiguration: transcriptionConfiguration,
            transcriptionModels: store.transcriptionModels,
            deepgramCredential: store.deepgramCredential,
            deepgramCredentialBusy: store.deepgramCredentialBusy,
            elevenLabsCredential: store.elevenLabsCredential,
            elevenLabsCredentialBusy: store.elevenLabsCredentialBusy,
            doubaoCredential: store.doubaoCredential,
            doubaoCredentialBusy: store.doubaoCredentialBusy,
            providerConfiguration: providerConfiguration,
            generationSettings: generationSettings,
            gptLiveBetaEnabled: gptLiveBetaEnabled,
            gptLiveCredential: gptLiveCredential,
            shortcutError: shortcutError,
            meetingAccessAuthorized: meetingAccessAuthorized,
            automaticMeetingPromptsEnabled: automaticMeetingPromptsEnabled,
            transcriptStorage: store.storageSettings,
            transcriptStorageChanging: store.storageChanging,
            notesStorage: store.notesStorageSettings,
            notesStorageChanging: store.notesStorageChanging,
            update: updateManager.state,
            currentVersion: updateManager.currentVersion
        )
    }

    private var settingsActions: SettingsSheetActions {
        SettingsSheetActions(
            onClose: { [weak self] in self?.closeSettings() },
            onChangeLocale: { [weak self] in self?.changeLocale($0) },
            onChangeAudioMode: { [weak self] in self?.changeAudioMode($0) },
            onChangeTranscriptionConfiguration: { [weak self] in self?.changeTranscriptionConfiguration($0) },
            onPrepareTranscriptionModel: { [weak self] model in self?.prepareModel(model) },
            onRemoveTranscriptionModel: { [weak self] model in self?.removeModel(model) },
            onSaveDeepgramAPIKey: { [weak store] key in _ = try await store?.saveDeepgramAPIKey(key) },
            onRemoveDeepgramAPIKey: { [weak store] in _ = try await store?.removeDeepgramAPIKey() },
            onOpenDeepgramConsole: { [environment] in try await environment.openURL(URL(string: "https://console.deepgram.com/")!) },
            onSaveElevenLabsAPIKey: { [weak store] key in _ = try await store?.saveElevenLabsAPIKey(key) },
            onRemoveElevenLabsAPIKey: { [weak store] in _ = try await store?.removeElevenLabsAPIKey() },
            onOpenElevenLabsConsole: { [environment] in try await environment.openURL(URL(string: "https://elevenlabs.io/app/developers/api-keys")!) },
            onSaveDoubaoCredentials: { [weak store] appID, token in _ = try await store?.saveDoubaoCredentials(appId: appID, accessToken: token) },
            onRemoveDoubaoCredentials: { [weak store] in _ = try await store?.removeDoubaoCredentials() },
            onOpenDoubaoConsole: { [environment] in try await environment.openURL(URL(string: "https://console.volcengine.com/speech/app")!) },
            onEditProviders: { [weak self] in self?.openProviderSetup() },
            onChangeGenerationSettings: { [weak self] in self?.changeGenerationSettings($0) },
            onChangeGPTLiveBetaEnabled: { [weak self] in self?.changeGPTLiveBetaEnabled($0) },
            onConnectGPTLiveCredential: { [weak self] in
                guard let self else { return .missing }
                return try await self.connectGPTLiveCredential()
            },
            onDisconnectGPTLiveCredential: { [weak self] in
                guard let self else { return .missing }
                return try await self.disconnectGPTLiveCredential()
            },
            onChooseTranscriptDirectory: { [weak self] in await self?.chooseTranscriptDirectory() ?? false },
            onResetTranscriptDirectory: { [weak self] in await self?.store.setTranscriptDirectory(nil, query: self?.query ?? "") ?? false },
            onChooseNotesDirectory: { [weak self] in await self?.chooseNotesDirectory() ?? false },
            onResetNotesDirectory: { [weak self] in await self?.store.setNotesDirectory(nil, query: self?.notesQuery ?? "") ?? false },
            onCheckForUpdates: { [weak self] in Task { await self?.checkForUpdates() } },
            onInstallUpdate: { [weak self] in Task { await self?.installUpdate() } },
            onRequestMeetingAccess: { [environment] in environment.requestMeetingAccess() },
            onResumeMeetingPrompts: { [environment] in environment.resumeMeetingPrompts() }
        )
    }

    private func updateSettingsViewModel() {
        settingsViewModelStorage?.updateExternalSnapshot(settingsSnapshot)
    }

    private func clearMeetingQuery() {
        meetingSearchTask?.cancel()
        meetingSearchTask = nil
        query = ""
    }

    private func startNotesRefreshIfNeeded() {
        let requestedQuery = notesQuery
        guard store.lastSuccessfulNotesQuery != requestedQuery,
              pendingNotesQuery != requestedQuery
        else { return }

        notesLoadTask?.cancel()
        pendingNotesQuery = requestedQuery
        notesLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.store.refreshSavedNotes(requestedQuery)
            guard self.pendingNotesQuery == requestedQuery else { return }
            self.pendingNotesQuery = nil
            self.notesLoadTask = nil
        }
    }

    private func transition(to next: AppRoute) {
        if page == .notes, next != .notes {
            notesSearchTask?.cancel()
            notesSearchTask = nil
            notesLoadTask?.cancel()
            notesLoadTask = nil
            pendingNotesQuery = nil
            notesViewModelStorage?.teardown()
            notesViewModelStorage = nil
        }
        let meetingPages: Set<AppRoute> = [.current, .review]
        if meetingPages.contains(page), !meetingPages.contains(next) {
            topBarViewModelStorage = nil
        }
        page = next
    }

    private func dismissSettings(restoringTriggerFocus: Bool = false) {
        guard settingsOpen || settingsViewModelStorage != nil else { return }
        settingsGeneration += 1
        settingsOpen = false
        settingsViewModelStorage = nil
        if restoringTriggerFocus {
            objectWillChange.send()
            settingsFocusRestoreGeneration += 1
        }
        Task { await shortcutViewModel.teardown() }
    }

    private func saveProviderConfiguration(_ configuration: ProviderConfiguration) {
        do {
            try preferences.saveProviderConfiguration(configuration)
            providerConfiguration = configuration
            updateSettingsViewModel()
        } catch { interfaceError = error.localizedDescription }
    }

    private func prepareModel(_ model: String) {
        if store.transcriptionModels.first(where: { $0.id == model })?.installed != true {
            store.mergeTranscriptionModelStatus(TranscriptionModelStatus(
                id: model,
                installed: false,
                phase: "downloading",
                progress: 0,
                error: nil,
                path: nil
            ))
        }
        Task { @MainActor [weak self] in
            do { _ = try await self?.store.prepareTranscriptionModel(model) }
            catch {
                self?.store.mergeTranscriptionModelStatus(TranscriptionModelStatus(
                    id: model,
                    installed: false,
                    phase: "failed",
                    progress: nil,
                    error: error.localizedDescription,
                    path: nil
                ))
            }
        }
    }

    private func removeModel(_ model: String) {
        Task { @MainActor [weak self] in
            do { _ = try await self?.store.removeTranscriptionModel(model) }
            catch {
                self?.store.mergeTranscriptionModelStatus(TranscriptionModelStatus(
                    id: model,
                    installed: true,
                    phase: "failed",
                    progress: nil,
                    error: error.localizedDescription,
                    path: nil
                ))
            }
        }
    }

    private func chooseTranscriptDirectory() async -> Bool {
        guard let directory = await environment.chooseDirectory(translate("settings.chooseFolderDialogTitle", [:])) else {
            return false
        }
        return await store.setTranscriptDirectory(directory, query: query)
    }

    private func chooseNotesDirectory() async -> Bool {
        guard let directory = await environment.chooseDirectory(translate("settings.chooseNotesFolderDialogTitle", [:])) else {
            return false
        }
        return await store.setNotesDirectory(directory, query: notesQuery)
    }
}
