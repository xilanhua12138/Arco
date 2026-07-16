import Foundation
import SwiftUI

public struct SettingsSheetSnapshot: Equatable, Sendable {
    public var isDesktop: Bool
    public var locale: String
    public var runtimes: [RuntimeStatus]
    public var audioMode: AudioMode
    public var audioModeLocked: Bool
    public var transcriptionConfiguration: TranscriptionConfiguration
    public var transcriptionModels: [TranscriptionModelStatus]
    public var deepgramCredential: CredentialStatus
    public var deepgramCredentialBusy: Bool
    public var elevenLabsCredential: CredentialStatus
    public var elevenLabsCredentialBusy: Bool
    public var doubaoCredential: DoubaoCredentialStatus
    public var doubaoCredentialBusy: Bool
    public var providerConfiguration: ProviderConfiguration
    public var generationSettings: GenerationSettings
    public var shortcutError: String?
    public var transcriptStorage: StorageSettings
    public var transcriptStorageChanging: Bool
    public var notesStorage: StorageSettings
    public var notesStorageChanging: Bool

    public init(
        isDesktop: Bool = true,
        locale: String = "en",
        runtimes: [RuntimeStatus] = [],
        audioMode: AudioMode = .both,
        audioModeLocked: Bool = false,
        transcriptionConfiguration: TranscriptionConfiguration = .default,
        transcriptionModels: [TranscriptionModelStatus] = [],
        deepgramCredential: CredentialStatus = .missing,
        deepgramCredentialBusy: Bool = false,
        elevenLabsCredential: CredentialStatus = .missing,
        elevenLabsCredentialBusy: Bool = false,
        doubaoCredential: DoubaoCredentialStatus = .missing,
        doubaoCredentialBusy: Bool = false,
        providerConfiguration: ProviderConfiguration = ProviderConfiguration(),
        generationSettings: GenerationSettings = .default,
        shortcutError: String? = nil,
        transcriptStorage: StorageSettings? = nil,
        transcriptStorageChanging: Bool = false,
        notesStorage: StorageSettings? = nil,
        notesStorageChanging: Bool = false
    ) {
        self.isDesktop = isDesktop
        self.locale = locale
        self.runtimes = runtimes
        self.audioMode = audioMode
        self.audioModeLocked = audioModeLocked
        self.transcriptionConfiguration = transcriptionConfiguration
        self.transcriptionModels = transcriptionModels
        self.deepgramCredential = deepgramCredential
        self.deepgramCredentialBusy = deepgramCredentialBusy
        self.elevenLabsCredential = elevenLabsCredential
        self.elevenLabsCredentialBusy = elevenLabsCredentialBusy
        self.doubaoCredential = doubaoCredential
        self.doubaoCredentialBusy = doubaoCredentialBusy
        self.providerConfiguration = providerConfiguration
        self.generationSettings = generationSettings
        self.shortcutError = shortcutError
        self.transcriptStorage = transcriptStorage ?? StorageSettings(
            defaultDirectory: "~/Library/Application Support/Arco/transcripts",
            selectedDirectory: "~/Library/Application Support/Arco/transcripts",
            usingDefault: true
        )
        self.transcriptStorageChanging = transcriptStorageChanging
        self.notesStorage = notesStorage ?? StorageSettings(
            defaultDirectory: "~/Library/Application Support/Arco/notes",
            selectedDirectory: "~/Library/Application Support/Arco/notes",
            usingDefault: true
        )
        self.notesStorageChanging = notesStorageChanging
    }
}

@MainActor
public struct SettingsSheetActions {
    public var onClose: () -> Void
    public var onChangeLocale: (String) -> Void
    public var onChangeAudioMode: (AudioMode) -> Void
    public var onChangeTranscriptionConfiguration: (TranscriptionConfiguration) -> Void
    public var onPrepareTranscriptionModel: (String) -> Void
    public var onRemoveTranscriptionModel: (String) -> Void
    public var onSaveDeepgramAPIKey: (String) async throws -> Void
    public var onRemoveDeepgramAPIKey: () async throws -> Void
    public var onOpenDeepgramConsole: () async throws -> Void
    public var onSaveElevenLabsAPIKey: (String) async throws -> Void
    public var onRemoveElevenLabsAPIKey: () async throws -> Void
    public var onOpenElevenLabsConsole: () async throws -> Void
    public var onSaveDoubaoCredentials: (String, String) async throws -> Void
    public var onRemoveDoubaoCredentials: () async throws -> Void
    public var onOpenDoubaoConsole: () async throws -> Void
    public var onEditProviders: () -> Void
    public var onChangeGenerationSettings: (GenerationSettings) -> Void
    public var onChooseTranscriptDirectory: () async -> Bool
    public var onResetTranscriptDirectory: () async -> Bool
    public var onChooseNotesDirectory: () async -> Bool
    public var onResetNotesDirectory: () async -> Bool

    public init(
        onClose: @escaping () -> Void,
        onChangeLocale: @escaping (String) -> Void = { _ in },
        onChangeAudioMode: @escaping (AudioMode) -> Void = { _ in },
        onChangeTranscriptionConfiguration: @escaping (TranscriptionConfiguration) -> Void = { _ in },
        onPrepareTranscriptionModel: @escaping (String) -> Void = { _ in },
        onRemoveTranscriptionModel: @escaping (String) -> Void = { _ in },
        onSaveDeepgramAPIKey: @escaping (String) async throws -> Void = { _ in },
        onRemoveDeepgramAPIKey: @escaping () async throws -> Void = {},
        onOpenDeepgramConsole: @escaping () async throws -> Void = {},
        onSaveElevenLabsAPIKey: @escaping (String) async throws -> Void = { _ in },
        onRemoveElevenLabsAPIKey: @escaping () async throws -> Void = {},
        onOpenElevenLabsConsole: @escaping () async throws -> Void = {},
        onSaveDoubaoCredentials: @escaping (String, String) async throws -> Void = { _, _ in },
        onRemoveDoubaoCredentials: @escaping () async throws -> Void = {},
        onOpenDoubaoConsole: @escaping () async throws -> Void = {},
        onEditProviders: @escaping () -> Void = {},
        onChangeGenerationSettings: @escaping (GenerationSettings) -> Void = { _ in },
        onChooseTranscriptDirectory: @escaping () async -> Bool = { true },
        onResetTranscriptDirectory: @escaping () async -> Bool = { true },
        onChooseNotesDirectory: @escaping () async -> Bool = { true },
        onResetNotesDirectory: @escaping () async -> Bool = { true }
    ) {
        self.onClose = onClose
        self.onChangeLocale = onChangeLocale
        self.onChangeAudioMode = onChangeAudioMode
        self.onChangeTranscriptionConfiguration = onChangeTranscriptionConfiguration
        self.onPrepareTranscriptionModel = onPrepareTranscriptionModel
        self.onRemoveTranscriptionModel = onRemoveTranscriptionModel
        self.onSaveDeepgramAPIKey = onSaveDeepgramAPIKey
        self.onRemoveDeepgramAPIKey = onRemoveDeepgramAPIKey
        self.onOpenDeepgramConsole = onOpenDeepgramConsole
        self.onSaveElevenLabsAPIKey = onSaveElevenLabsAPIKey
        self.onRemoveElevenLabsAPIKey = onRemoveElevenLabsAPIKey
        self.onOpenElevenLabsConsole = onOpenElevenLabsConsole
        self.onSaveDoubaoCredentials = onSaveDoubaoCredentials
        self.onRemoveDoubaoCredentials = onRemoveDoubaoCredentials
        self.onOpenDoubaoConsole = onOpenDoubaoConsole
        self.onEditProviders = onEditProviders
        self.onChangeGenerationSettings = onChangeGenerationSettings
        self.onChooseTranscriptDirectory = onChooseTranscriptDirectory
        self.onResetTranscriptDirectory = onResetTranscriptDirectory
        self.onChooseNotesDirectory = onChooseNotesDirectory
        self.onResetNotesDirectory = onResetNotesDirectory
    }
}

public enum SettingsCredentialProvider: String, Sendable {
    case deepgram
    case elevenLabs
    case doubao
}

@MainActor
public final class SettingsSheetViewModel: ObservableObject {
    @Published public var page: SettingsPage {
        didSet {
            guard oldValue != page else { return }
            if oldValue == .general {
                Task { await shortcutViewModel.teardown() }
            }
            if oldValue == .output {
                outputViewModel.teardown()
            }
            if oldValue == .audio || page == .audio {
                recognitionExpanded = true
            }
        }
    }
    @Published public private(set) var snapshot: SettingsSheetSnapshot
    @Published public var deepgramAPIKey = ""
    @Published public var elevenLabsAPIKey = ""
    @Published public var doubaoAppID = ""
    @Published public var doubaoAccessToken = ""
    @Published public private(set) var deepgramError: String?
    @Published public private(set) var elevenLabsError: String?
    @Published public private(set) var doubaoError: String?
    @Published public var recognitionExpanded = true

    public let shortcutViewModel: ShortcutRecorderViewModel
    public let outputViewModel: MeetingOutputSettingsViewModel
    public let actions: SettingsSheetActions

    public init(
        snapshot: SettingsSheetSnapshot,
        initialPage: SettingsPage = .audio,
        shortcutViewModel: ShortcutRecorderViewModel,
        actions: SettingsSheetActions
    ) {
        self.snapshot = snapshot
        page = initialPage
        self.shortcutViewModel = shortcutViewModel
        self.actions = actions
        outputViewModel = MeetingOutputSettingsViewModel(
            settings: snapshot.generationSettings,
            onSave: actions.onChangeGenerationSettings
        )
    }

    public func updateExternalSnapshot(_ snapshot: SettingsSheetSnapshot) {
        self.snapshot = snapshot
        outputViewModel.updateExternalSettings(snapshot.generationSettings)
    }

    public var selectedASRModel: LocalModelDescriptor? {
        arcoLocalASRModels.first { $0.id == snapshot.transcriptionConfiguration.asr.model }
    }

    public var selectedASRModelStatus: TranscriptionModelStatus? {
        modelStatus(snapshot.transcriptionConfiguration.asr.model)
    }

    public var selectedDiarizationModel: LocalModelDescriptor? {
        guard snapshot.transcriptionConfiguration.diarization.provider == .local,
              let model = snapshot.transcriptionConfiguration.diarization.model
        else { return nil }
        return arcoLocalDiarizationModels.first { $0.id == model }
    }

    public var selectedDiarizationModelStatus: TranscriptionModelStatus? {
        selectedDiarizationModel.flatMap { modelStatus($0.id) }
    }

    public var localSetupIncomplete: Bool {
        let configuration = snapshot.transcriptionConfiguration
        let asrMissing = configuration.asr.provider == .local && selectedASRModelStatus?.installed != true
        let diarizationMissing = configuration.diarization.provider == .local && selectedDiarizationModelStatus?.installed != true
        return asrMissing || diarizationMissing
    }

    public func modelStatus(_ id: String) -> TranscriptionModelStatus? {
        snapshot.transcriptionModels.first { $0.id == id }
    }

    public func modelBusy(_ id: String) -> Bool {
        guard let phase = modelStatus(id)?.phase else { return false }
        return ["downloading", "optimizing", "loading"].contains(phase)
    }

    public func setLocale(_ locale: String) {
        snapshot.locale = locale
        actions.onChangeLocale(locale)
    }

    public func setAudioMode(_ mode: AudioMode) {
        guard !snapshot.audioModeLocked else { return }
        snapshot.audioMode = mode
        actions.onChangeAudioMode(mode)
    }

    public func changeEngine(_ provider: TranscriptionProvider) {
        guard !snapshot.audioModeLocked else { return }
        var next = snapshot.transcriptionConfiguration
        switch provider {
        case .deepgram:
            next.asr = ASRConfiguration(
                provider: .deepgram,
                model: "nova-3",
                language: next.asr.language == "auto" ? "zh-CN" : next.asr.language
            )
        case .elevenlabs:
            next.asr = ASRConfiguration(provider: .elevenlabs, model: "scribe-v2-realtime", language: next.asr.language)
        case .doubao:
            next.asr = ASRConfiguration(provider: .doubao, model: "bigmodel", language: next.asr.language)
            if next.diarization.provider == .deepgram {
                next.diarization = DiarizationConfiguration(provider: .doubao, model: "bigmodel")
            }
        case .local:
            next.asr = ASRConfiguration(
                provider: .local,
                model: selectedASRModel?.id ?? "nemotron-speech-3.5-streaming",
                language: next.asr.language
            )
        }
        commitTranscription(next)
    }

    public func setASRModel(_ model: String) {
        guard !snapshot.audioModeLocked, TranscriptionConfiguration.localASRModels.contains(model) else { return }
        var next = snapshot.transcriptionConfiguration
        next.asr.provider = .local
        next.asr.model = model
        commitTranscription(next)
    }

    public func setLanguage(_ language: String) {
        guard !snapshot.audioModeLocked, ["auto", "zh-CN", "en-US"].contains(language) else { return }
        var next = snapshot.transcriptionConfiguration
        next.asr.language = language
        commitTranscription(next)
    }

    public func changeDiarizationLocation(_ location: String) {
        guard !snapshot.audioModeLocked else { return }
        var next = snapshot.transcriptionConfiguration
        switch location {
        case "cloud":
            let useDoubao = next.diarization.provider == .doubao || next.asr.provider == .doubao
            next.diarization = DiarizationConfiguration(
                provider: useDoubao ? .doubao : .deepgram,
                model: useDoubao ? "bigmodel" : "latest"
            )
        case "local":
            next.diarization = DiarizationConfiguration(
                provider: .local,
                model: selectedDiarizationModel?.id ?? "sortformer-streaming"
            )
        default:
            next.diarization = DiarizationConfiguration(provider: .none, model: nil)
        }
        commitTranscription(next)
    }

    public func changeDiarizationProvider(_ provider: DiarizationProvider) {
        guard !snapshot.audioModeLocked, provider == .deepgram || provider == .doubao else { return }
        var next = snapshot.transcriptionConfiguration
        next.diarization = DiarizationConfiguration(
            provider: provider,
            model: provider == .doubao ? "bigmodel" : "latest"
        )
        commitTranscription(next)
    }

    public func setDiarizationModel(_ model: String) {
        guard !snapshot.audioModeLocked, TranscriptionConfiguration.localDiarizationModels.contains(model) else { return }
        var next = snapshot.transcriptionConfiguration
        next.diarization = DiarizationConfiguration(provider: .local, model: model)
        commitTranscription(next)
    }

    public func prepareModel(_ id: String) {
        guard !snapshot.audioModeLocked, !modelBusy(id) else { return }
        actions.onPrepareTranscriptionModel(id)
    }

    public func removeModel(_ id: String) {
        guard !snapshot.audioModeLocked else { return }
        actions.onRemoveTranscriptionModel(id)
    }

    public func saveCredential(_ provider: SettingsCredentialProvider) async {
        switch provider {
        case .deepgram:
            let key = deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            deepgramError = nil
            do {
                try await actions.onSaveDeepgramAPIKey(key)
                deepgramAPIKey = ""
            } catch { deepgramError = error.localizedDescription }
        case .elevenLabs:
            let key = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            elevenLabsError = nil
            do {
                try await actions.onSaveElevenLabsAPIKey(key)
                elevenLabsAPIKey = ""
            } catch { elevenLabsError = error.localizedDescription }
        case .doubao:
            let appID = doubaoAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = doubaoAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appID.isEmpty else { return }
            doubaoError = nil
            do {
                try await actions.onSaveDoubaoCredentials(appID, token)
                doubaoAppID = ""
                doubaoAccessToken = ""
            } catch { doubaoError = error.localizedDescription }
        }
    }

    public func removeCredential(_ provider: SettingsCredentialProvider) async {
        switch provider {
        case .deepgram:
            try? await actions.onRemoveDeepgramAPIKey()
        case .elevenLabs:
            try? await actions.onRemoveElevenLabsAPIKey()
        case .doubao:
            try? await actions.onRemoveDoubaoCredentials()
        }
    }

    public func openCredentialConsole(_ provider: SettingsCredentialProvider) async {
        do {
            switch provider {
            case .deepgram:
                deepgramError = nil
                try await actions.onOpenDeepgramConsole()
            case .elevenLabs:
                elevenLabsError = nil
                try await actions.onOpenElevenLabsConsole()
            case .doubao:
                doubaoError = nil
                try await actions.onOpenDoubaoConsole()
            }
        } catch {
            setCredentialError(error.localizedDescription, provider: provider)
        }
    }

    public func chooseTranscriptDirectory() async {
        guard !snapshot.audioModeLocked, !snapshot.transcriptStorageChanging else { return }
        _ = await actions.onChooseTranscriptDirectory()
    }

    public func resetTranscriptDirectory() async {
        guard !snapshot.audioModeLocked, !snapshot.transcriptStorageChanging else { return }
        _ = await actions.onResetTranscriptDirectory()
    }

    public func chooseNotesDirectory() async {
        guard !snapshot.notesStorageChanging else { return }
        _ = await actions.onChooseNotesDirectory()
    }

    public func resetNotesDirectory() async {
        guard !snapshot.notesStorageChanging else { return }
        _ = await actions.onResetNotesDirectory()
    }

    private func commitTranscription(_ next: TranscriptionConfiguration) {
        snapshot.transcriptionConfiguration = next
        actions.onChangeTranscriptionConfiguration(next)
    }

    private func setCredentialError(_ message: String, provider: SettingsCredentialProvider) {
        switch provider {
        case .deepgram: deepgramError = message
        case .elevenLabs: elevenLabsError = message
        case .doubao: doubaoError = message
        }
    }
}
