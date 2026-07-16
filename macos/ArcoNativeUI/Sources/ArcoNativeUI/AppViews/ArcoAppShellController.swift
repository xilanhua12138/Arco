import AppKit
import Foundation
import SwiftUI

@MainActor
public struct ArcoAppEnvironment {
    public var chooseDirectory: (_ title: String) async -> String?
    public var chooseWorkspace: (_ title: String) async -> String?
    public var copyText: (_ text: String) async throws -> Void
    public var openURL: (_ url: URL) async throws -> Void
    public var changeListeningShortcut: (_ shortcut: ListeningShortcut?) async -> Bool
    public var startListeningShortcutRecording: () async -> Bool
    public var cancelListeningShortcutRecording: () async -> Void
    public var localeChanged: (_ locale: AppLocale) -> Void
    public var relaunch: () async -> Void

    public init(
        chooseDirectory: @escaping (_ title: String) async -> String? = ArcoAppEnvironment.nativeDirectoryPicker,
        chooseWorkspace: @escaping (_ title: String) async -> String? = ArcoAppEnvironment.nativeDirectoryPicker,
        copyText: @escaping (_ text: String) async throws -> Void = ArcoAppEnvironment.nativeCopy,
        openURL: @escaping (_ url: URL) async throws -> Void = ArcoAppEnvironment.nativeOpenURL,
        changeListeningShortcut: @escaping (_ shortcut: ListeningShortcut?) async -> Bool = { _ in true },
        startListeningShortcutRecording: @escaping () async -> Bool = { true },
        cancelListeningShortcutRecording: @escaping () async -> Void = {},
        localeChanged: @escaping (_ locale: AppLocale) -> Void = { _ in },
        relaunch: @escaping () async -> Void = {}
    ) {
        self.chooseDirectory = chooseDirectory
        self.chooseWorkspace = chooseWorkspace
        self.copyText = copyText
        self.openURL = openURL
        self.changeListeningShortcut = changeListeningShortcut
        self.startListeningShortcutRecording = startListeningShortcutRecording
        self.cancelListeningShortcutRecording = cancelListeningShortcutRecording
        self.localeChanged = localeChanged
        self.relaunch = relaunch
    }

    public static func nativeDirectoryPicker(_ title: String) async -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
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

    public let store: ArcoStore
    public let preferences: ArcoPreferences
    public let environment: ArcoAppEnvironment
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
    private var loadedNotesQuery: String?
    private var openedCompletedMeetingID: String?
    private var topBarViewModelStorage: TopBarViewModel?
    private var notesViewModelStorage: NotesPageViewModel?
    private var settingsViewModelStorage: SettingsSheetViewModel?
    private var providerViewModelStorage: ProviderSetupViewModel?
    private var onboardingViewModelStorage: OnboardingViewModel?
    private var settingsGeneration = 0

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
        audioMode = preferences.loadAudioMode()
        let initialProviderConfiguration = preferences.loadProviderConfiguration()
        providerConfiguration = initialProviderConfiguration
        generationSettings = preferences.loadGenerationSettings()
        transcriptionConfiguration = preferences.loadTranscriptionConfiguration()
        listeningShortcut = preferences.loadListeningShortcut()
        locale = preferences.loadLocale()
        agentWorkspace = preferences.loadAgentWorkspace()
        let onboarding = preferences.loadOnboardingState()
        providerSetupOpen = !initialProviderConfiguration.setupComplete && !onboarding.completed

    }

    deinit {
        meetingSearchTask?.cancel()
        notesSearchTask?.cancel()
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
        updateDependentViewModels()
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
        notesSearchTask?.cancel()
        notesSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  let self,
                  self.page == .notes,
                  self.notesQuery == value
            else { return }
            self.loadedNotesQuery = value
            _ = await self.store.refreshSavedNotes(value)
        }
    }

    public func showPage(_ next: AppRoute) async {
        dismissSettings()
        if next == .notes {
            transition(to: .notes)
            if loadedNotesQuery != notesQuery {
                loadedNotesQuery = notesQuery
                _ = await store.refreshSavedNotes(notesQuery)
            }
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
        guard store.capture.phase != .starting, store.capture.phase != .stopping else { return }
        if store.capture.phase == .recording, page == .current {
            topBarViewModelStorage = nil
        }
        let next = await store.toggleCapture(
            mode: audioMode,
            transcription: transcriptionConfiguration,
            resumeMeetingId: resumeMeetingID
        )
        if next?.phase == .recording { transition(to: .current) }
    }

    public func captureCompletedMeetingChanged() {
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
            shortcutError: shortcutError,
            transcriptStorage: store.storageSettings,
            transcriptStorageChanging: store.storageChanging,
            notesStorage: store.notesStorageSettings,
            notesStorageChanging: store.notesStorageChanging
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
            onChooseTranscriptDirectory: { [weak self] in await self?.chooseTranscriptDirectory() ?? false },
            onResetTranscriptDirectory: { [weak self] in await self?.store.setTranscriptDirectory(nil, query: self?.query ?? "") ?? false },
            onChooseNotesDirectory: { [weak self] in await self?.chooseNotesDirectory() ?? false },
            onResetNotesDirectory: { [weak self] in await self?.store.setNotesDirectory(nil, query: self?.notesQuery ?? "") ?? false }
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

    private func transition(to next: AppRoute) {
        if page == .notes, next != .notes {
            notesSearchTask?.cancel()
            notesSearchTask = nil
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
