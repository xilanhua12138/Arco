import Combine
import Foundation

private enum OnboardingSourceParityError: LocalizedError {
    case primaryProviderUnavailable
    case providersMustDiffer
    case secondaryProviderUnavailable

    var errorDescription: String? {
        switch self {
        case .primaryProviderUnavailable:
            "The primary provider must be available."
        case .providersMustDiffer:
            "Primary and secondary providers must be different."
        case .secondaryProviderUnavailable:
            "The secondary provider must be available."
        }
    }
}

@MainActor
public final class OnboardingViewModel: ObservableObject {
    public static let restartRequiredPrefix = "ARCO_AUDIO_PERMISSION_RESTART_REQUIRED:"

    @Published public private(set) var runtimes: [RuntimeStatus]
    @Published public private(set) var step: Int
    @Published public private(set) var furthestStep: Int
    @Published public private(set) var agentChoice: OnboardingAgentChoice
    @Published public private(set) var selectedPrimary: ProviderID?
    @Published public private(set) var secondary: ProviderID?
    @Published public private(set) var providerTest: SetupAsyncState
    @Published public private(set) var testedProvider: ProviderID?
    @Published public private(set) var providerTestError: String?
    @Published public private(set) var refreshing = false

    @Published public private(set) var transcription: TranscriptionConfiguration
    @Published public private(set) var models: [TranscriptionModelStatus]
    @Published public private(set) var deepgramCredential: CredentialStatus
    @Published public private(set) var elevenLabsCredential: CredentialStatus
    @Published public private(set) var doubaoCredential: DoubaoCredentialStatus
    @Published public var apiKey = ""
    @Published public var doubaoAppID = ""
    @Published public var doubaoAccessToken = ""
    @Published public private(set) var transcriptionState: SetupAsyncState = .idle
    @Published public private(set) var transcriptionError: String?
    @Published public private(set) var preparingModelID: String?
    @Published public private(set) var modelErrors: [String: String] = [:]

    @Published public private(set) var audioChecks: [OnboardingAudioSource: OnboardingAudioSourceState]
    @Published public private(set) var workingAudioSource: OnboardingAudioSource?
    @Published public private(set) var audioCountdown = 3

    @Published public private(set) var shortcut: ListeningShortcut?
    @Published public private(set) var shortcutTestBaseline: Int
    @Published public private(set) var shortcutRecording = false
    @Published public private(set) var finishing = false

    private let onRefreshRuntimes: () async throws -> [RuntimeStatus]?
    private let onTestProvider: (ProviderID) async throws -> ProviderConnectionTest
    private let onSaveDeepgramAPIKey: (String) async throws -> CredentialStatus
    private let onSaveElevenLabsAPIKey: (String) async throws -> CredentialStatus
    private let onSaveDoubaoCredentials: (String, String) async throws -> DoubaoCredentialStatus
    private let onPrepareTranscriptionModel: (String) async throws -> [TranscriptionModelStatus]
    private let onTestAudio: (AudioMode) async throws -> AudioSetupCheck
    private let onRelaunch: () async -> Void
    private let saveDraft: (OnboardingDraftState) -> Void
    private let clearDraft: () -> Void
    private let onComplete: (OnboardingResult) async throws -> Void
    private let onSkip: () -> Void
    private var countdownTask: Task<Void, Never>?
    private var modelsOverriddenLocally = false
    private var deepgramCredentialOverriddenLocally = false
    private var elevenLabsCredentialOverriddenLocally = false
    private var doubaoCredentialOverriddenLocally = false

    public init(
        runtimes: [RuntimeStatus],
        transcriptionConfiguration: TranscriptionConfiguration,
        transcriptionModels: [TranscriptionModelStatus],
        deepgramCredential: CredentialStatus,
        elevenLabsCredential: CredentialStatus,
        doubaoCredential: DoubaoCredentialStatus = .missing,
        listeningShortcut: ListeningShortcut?,
        shortcutTestCount: Int,
        restoredDraft: OnboardingDraftState? = nil,
        onRefreshRuntimes: @escaping () async throws -> [RuntimeStatus]?,
        onTestProvider: @escaping (ProviderID) async throws -> ProviderConnectionTest,
        onSaveDeepgramAPIKey: @escaping (String) async throws -> CredentialStatus,
        onSaveElevenLabsAPIKey: @escaping (String) async throws -> CredentialStatus,
        onSaveDoubaoCredentials: @escaping (String, String) async throws -> DoubaoCredentialStatus,
        onPrepareTranscriptionModel: @escaping (String) async throws -> [TranscriptionModelStatus],
        onTestAudio: @escaping (AudioMode) async throws -> AudioSetupCheck,
        onRelaunch: @escaping () async -> Void,
        saveDraft: @escaping (OnboardingDraftState) -> Void = { _ in },
        clearDraft: @escaping () -> Void = {},
        onComplete: @escaping (OnboardingResult) async throws -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.runtimes = runtimes
        step = restoredDraft?.step ?? 0
        furthestStep = restoredDraft?.furthestStep ?? 0
        agentChoice = restoredDraft?.agentChoice ?? .agent
        selectedPrimary = restoredDraft?.primary
        secondary = restoredDraft?.secondary
        testedProvider = restoredDraft?.testedProvider
        let restoredTestIsLegal = restoredDraft?.testedProvider != nil
            && restoredDraft?.testedProvider == restoredDraft?.primary
            && runtimes.contains { $0.provider == restoredDraft?.primary && $0.available }
        providerTest = restoredTestIsLegal ? .passed : .idle
        providerTestError = nil
        transcription = restoredDraft?.transcriptionConfiguration ?? transcriptionConfiguration
        models = transcriptionModels
        self.deepgramCredential = deepgramCredential
        self.elevenLabsCredential = elevenLabsCredential
        self.doubaoCredential = doubaoCredential
        audioChecks = [.system: .init(), .microphone: .init()]
        shortcut = restoredDraft?.listeningShortcut ?? listeningShortcut
        shortcutTestBaseline = shortcutTestCount
        self.onRefreshRuntimes = onRefreshRuntimes
        self.onTestProvider = onTestProvider
        self.onSaveDeepgramAPIKey = onSaveDeepgramAPIKey
        self.onSaveElevenLabsAPIKey = onSaveElevenLabsAPIKey
        self.onSaveDoubaoCredentials = onSaveDoubaoCredentials
        self.onPrepareTranscriptionModel = onPrepareTranscriptionModel
        self.onTestAudio = onTestAudio
        self.onRelaunch = onRelaunch
        self.saveDraft = saveDraft
        self.clearDraft = clearDraft
        self.onComplete = onComplete
        self.onSkip = onSkip
        // The React persistence effect runs once after a resumed non-landing
        // step mounts, which also records any provider fallback derived from
        // the current runtime props.
        if step != 0 { self.saveDraft(self.draft) }
    }

    deinit { countdownTask?.cancel() }

    public var firstAvailableProvider: ProviderID? {
        ProviderID.allCases.first { runtime(for: $0)?.available == true }
    }

    public var primary: ProviderID? { selectedPrimary ?? firstAvailableProvider }

    public var selectedLocalModelID: String {
        transcription.asr.provider == .local ? transcription.asr.model : "nemotron-speech-3.5-streaming"
    }

    public var selectedDiarizationModelID: String {
        transcription.diarization.provider == .local
            ? transcription.diarization.model ?? "sortformer-streaming"
            : "sortformer-streaming"
    }

    public var currentASRCredential: CredentialStatus {
        switch transcription.asr.provider {
        case .elevenlabs: elevenLabsCredential
        case .doubao: CredentialStatus(configured: doubaoCredential.configured, verified: doubaoCredential.verified, message: doubaoCredential.message)
        case .deepgram, .local: deepgramCredential
        }
    }

    public var providerReady: Bool {
        agentChoice == .transcript || (primary != nil && providerTest == .passed && testedProvider == primary)
    }

    public var asrReady: Bool {
        if transcription.asr.provider == .local { return modelReady(selectedLocalModelID) }
        return currentASRCredential.configured && currentASRCredential.verified
    }

    public var diarizationReady: Bool {
        switch transcription.diarization.provider {
        case .none: true
        case .local: modelReady(selectedDiarizationModelID)
        case .doubao: doubaoCredential.configured && doubaoCredential.verified
        case .deepgram: deepgramCredential.configured && deepgramCredential.verified
        }
    }

    public var transcriptionReady: Bool { asrReady && diarizationReady }

    public var audioReady: Bool {
        OnboardingAudioSource.allCases.allSatisfy { source in
            audioChecks[source]?.state == .passed && audioChecks[source]?.result?.ready == true
        }
    }

    public var canContinue: Bool {
        switch step {
        case 0: true
        case 1: providerReady
        case 2: transcriptionReady
        case 3: audioReady
        case 4: true
        default: false
        }
    }

    public var draft: OnboardingDraftState {
        OnboardingDraftState(
            step: max(1, min(5, step)),
            furthestStep: max(1, min(5, furthestStep)),
            agentChoice: agentChoice,
            primary: primary,
            secondary: secondary,
            testedProvider: providerTest == .passed ? testedProvider : nil,
            transcriptionConfiguration: transcription,
            audioMode: .both,
            listeningShortcut: shortcut
        )
    }

    public func runtime(for provider: ProviderID) -> RuntimeStatus? {
        runtimes.first { $0.provider == provider }
    }

    public func modelStatus(_ id: String) -> TranscriptionModelStatus? {
        models.first { $0.id == id }
    }

    public func modelReady(_ id: String) -> Bool {
        models.contains { $0.id == id && $0.installed && $0.phase == "ready" }
    }

    public func modelBusy(_ id: String) -> Bool {
        ["downloading", "optimizing", "loading"].contains(modelStatus(id)?.phase)
    }

    /// Mirrors the React component's prop-or-local-override behavior. External
    /// setup state stays live until an action inside onboarding produces a
    /// corresponding local result.
    public func updateExternalSetupStatus(
        runtimes: [RuntimeStatus],
        models: [TranscriptionModelStatus],
        deepgramCredential: CredentialStatus,
        elevenLabsCredential: CredentialStatus,
        doubaoCredential: DoubaoCredentialStatus
    ) {
        let previousDraft = draft
        self.runtimes = runtimes
        updateExternalModels(models)
        if !deepgramCredentialOverriddenLocally {
            self.deepgramCredential = deepgramCredential
        }
        if !elevenLabsCredentialOverriddenLocally {
            self.elevenLabsCredential = elevenLabsCredential
        }
        if !doubaoCredentialOverriddenLocally {
            self.doubaoCredential = doubaoCredential
        }
        if draft != previousDraft { persistDraft() }
    }

    /// Keeps long-running model download and optimization progress live while
    /// the model preparation call has not produced its local final snapshot.
    public func updateExternalModels(_ models: [TranscriptionModelStatus]) {
        if !modelsOverriddenLocally {
            self.models = models
        }
    }

    public func reveal(_ next: Int, shortcutTestCount: Int) {
        furthestStep = max(furthestStep, next)
        if next == 4 { shortcutTestBaseline = shortcutTestCount }
        step = next
        persistDraft()
    }

    public func move(to next: Int) {
        guard next <= furthestStep else { return }
        step = next
        persistDraft()
    }

    public func back() {
        if step > 0 { step -= 1 }
        persistDraft()
    }

    public func setAgentChoice(_ choice: OnboardingAgentChoice) {
        guard choice != .agent || firstAvailableProvider != nil else { return }
        agentChoice = choice
        persistDraft()
    }

    public func selectPrimary(_ provider: ProviderID) {
        guard runtime(for: provider)?.available == true else { return }
        selectedPrimary = provider
        if secondary == provider { secondary = nil }
        providerTest = .idle
        testedProvider = nil
        providerTestError = nil
        persistDraft()
    }

    public func selectSecondary(_ provider: ProviderID?) {
        if let provider {
            guard provider != primary, runtime(for: provider)?.available == true else { return }
        }
        secondary = provider
        persistDraft()
    }

    public func runProviderTest() async {
        guard let primary, providerTest != .working else { return }
        providerTest = .working
        testedProvider = primary
        providerTestError = nil
        // React persisted every draft-relevant state transition through its
        // effect, including invalidating an earlier pass before awaiting.
        persistDraft()
        do {
            let result = try await onTestProvider(primary)
            providerTest = result.ok ? .passed : .failed
            providerTestError = result.ok ? nil : result.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } catch {
            providerTest = .failed
            providerTestError = error.localizedDescription
        }
        persistDraft()
    }

    public func refreshRuntimeStatus() async throws {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let refreshed = try await onRefreshRuntimes() ?? runtimes
        runtimes = refreshed
        let primaryStillAvailable = primary.map { provider in
            refreshed.contains { $0.provider == provider && $0.available }
        } ?? false
        if !primaryStillAvailable {
            let fallback = ProviderID.allCases.first { provider in
                refreshed.contains { $0.provider == provider && $0.available }
            }
            selectedPrimary = fallback
            secondary = nil
            agentChoice = fallback == nil ? .transcript : .agent
        }
        providerTest = .idle
        testedProvider = nil
        providerTestError = nil
        persistDraft()
    }

    public func changeASRProvider(_ provider: TranscriptionProvider) {
        resetCredentialEntry()
        let model: String = switch provider {
        case .local: selectedLocalModelID
        case .deepgram: "nova-3"
        case .elevenlabs: "scribe-v2-realtime"
        case .doubao: "bigmodel"
        }
        transcription.asr = ASRConfiguration(provider: provider, model: model, language: transcription.asr.language)
        if provider == .doubao, transcription.diarization.provider == .deepgram {
            transcription.diarization = DiarizationConfiguration(provider: .doubao, model: "bigmodel")
        }
        persistDraft()
    }

    public func changeLanguage(_ language: String) {
        transcription.asr.language = language
        persistDraft()
    }

    public func changeLocalASRModel(_ id: String) {
        guard TranscriptionConfiguration.localASRModels.contains(id) else { return }
        transcription.asr = ASRConfiguration(provider: .local, model: id, language: transcription.asr.language)
        transcriptionError = nil
        persistDraft()
    }

    public func changeDiarizationProvider(_ provider: DiarizationProvider) {
        resetCredentialEntry()
        switch provider {
        case .deepgram: transcription.diarization = .init(provider: .deepgram, model: "latest")
        case .doubao: transcription.diarization = .init(provider: .doubao, model: "bigmodel")
        case .local: transcription.diarization = .init(provider: .local, model: selectedDiarizationModelID)
        case .none: transcription.diarization = .init(provider: .none, model: nil)
        }
        persistDraft()
    }

    public func changeDiarizationModel(_ id: String) {
        guard TranscriptionConfiguration.localDiarizationModels.contains(id) else { return }
        transcription.diarization = DiarizationConfiguration(provider: .local, model: id)
        transcriptionError = nil
        persistDraft()
    }

    public func saveCloudCredential(for provider: TranscriptionProvider) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, transcriptionState != .working else { return }
        transcriptionState = .working
        transcriptionError = nil
        do {
            let status: CredentialStatus
            if provider == .elevenlabs {
                status = try await onSaveElevenLabsAPIKey(key)
                elevenLabsCredential = status
                elevenLabsCredentialOverriddenLocally = true
            } else {
                status = try await onSaveDeepgramAPIKey(key)
                deepgramCredential = status
                deepgramCredentialOverriddenLocally = true
            }
            apiKey = ""
            transcriptionState = status.configured && status.verified ? .passed : .failed
        } catch {
            transcriptionState = .failed
            transcriptionError = error.localizedDescription
        }
    }

    public func saveDoubaoCredential() async {
        let appID = doubaoAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, transcriptionState != .working else { return }
        transcriptionState = .working
        transcriptionError = nil
        do {
            let status = try await onSaveDoubaoCredentials(
                appID,
                doubaoAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            doubaoCredential = status
            doubaoCredentialOverriddenLocally = true
            doubaoAppID = ""
            doubaoAccessToken = ""
            transcriptionState = status.configured && status.verified ? .passed : .failed
        } catch {
            transcriptionState = .failed
            transcriptionError = error.localizedDescription
        }
    }

    public func prepareModel(_ id: String, failureFallback: String) async {
        guard preparingModelID == nil, !modelBusy(id) else { return }
        preparingModelID = id
        modelErrors[id] = nil
        defer { preparingModelID = nil }
        do {
            let next = try await onPrepareTranscriptionModel(id)
            models = next
            modelsOverriddenLocally = true
            if let status = next.first(where: { $0.id == id }), !status.installed || status.phase != "ready" {
                modelErrors[id] = status.error ?? failureFallback
            } else if !next.contains(where: { $0.id == id && $0.installed && $0.phase == "ready" }) {
                modelErrors[id] = failureFallback
            }
        } catch {
            modelErrors[id] = error.localizedDescription
        }
    }

    public func runAudioCheck(_ source: OnboardingAudioSource, fallbackError: String) async {
        guard workingAudioSource == nil else { return }
        workingAudioSource = source
        audioChecks[source] = OnboardingAudioSourceState(state: .working)
        startCountdown()
        defer {
            countdownTask?.cancel()
            countdownTask = nil
            workingAudioSource = nil
        }
        do {
            let result = try await onTestAudio(source == .system ? .system : .mic)
            let sourceResult = source == .system ? result.system : result.microphone
            audioChecks[source] = OnboardingAudioSourceState(
                state: sourceResult.ready ? .passed : .failed,
                result: sourceResult
            )
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackError
            let restart = source == .system && message.hasPrefix(Self.restartRequiredPrefix)
            audioChecks[source] = OnboardingAudioSourceState(
                state: .failed,
                error: restart
                    ? String(message.dropFirst(Self.restartRequiredPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    : message,
                restartRequired: restart
            )
        }
    }

    public func relaunch() async {
        saveDraft(draft)
        await onRelaunch()
    }

    public func shortcutChanged(_ shortcut: ListeningShortcut?, testCount: Int) {
        self.shortcut = shortcut
        shortcutTestBaseline = testCount
        persistDraft()
    }

    public func shortcutRecordingChanged(_ recording: Bool, testCount: Int) {
        shortcutRecording = recording
        if recording { shortcutTestBaseline = testCount }
    }

    public func skip() {
        clearDraft()
        onSkip()
    }

    public func complete(startListening: Bool) async throws {
        guard !finishing else { return }
        finishing = true
        defer { finishing = false }
        let providerConfiguration: ProviderConfiguration
        if agentChoice == .agent {
            guard let primary, runtime(for: primary)?.available == true else {
                throw OnboardingSourceParityError.primaryProviderUnavailable
            }
            if secondary == primary {
                throw OnboardingSourceParityError.providersMustDiffer
            }
            if let secondary, runtime(for: secondary)?.available != true {
                throw OnboardingSourceParityError.secondaryProviderUnavailable
            }
            providerConfiguration = ProviderConfiguration(setupComplete: true, primary: primary, secondary: secondary)
        } else {
            providerConfiguration = ProviderConfiguration()
        }
        try await onComplete(
            OnboardingResult(
                providerConfiguration: providerConfiguration,
                transcriptionConfiguration: transcription,
                audioMode: .both,
                startListening: startListening
            )
        )
    }

    public func modelActionLabel(_ id: String, downloadLabel: String, downloadingLabel: String, optimizingLabel: String, loadingLabel: String) -> String {
        let status = modelStatus(id)
        if status?.phase == "downloading" { return "\(Int(((status?.progress ?? 0) * 100).rounded()))%" }
        if status?.phase == "optimizing" { return optimizingLabel }
        if status?.phase == "loading" { return loadingLabel }
        if preparingModelID == id { return downloadingLabel }
        return downloadLabel
    }

    private func resetCredentialEntry() {
        apiKey = ""
        doubaoAppID = ""
        doubaoAccessToken = ""
        transcriptionError = nil
        transcriptionState = .idle
    }

    private func persistDraft() {
        guard step != 0 else { return }
        saveDraft(draft)
    }

    private func startCountdown() {
        countdownTask?.cancel()
        audioCountdown = 3
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.audioCountdown = max(0, self.audioCountdown - 1)
            }
        }
    }
}
