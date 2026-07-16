import Foundation

extension String {
    /// Browser `maxLength` is measured in UTF-16 code units. Preserve that
    /// contract without leaving an unmatched surrogate at the truncation edge.
    func utf16Prefix(_ maximumCodeUnits: Int) -> String {
        guard maximumCodeUnits > 0 else { return "" }
        guard utf16.count > maximumCodeUnits else { return self }
        var units = Array(utf16.prefix(maximumCodeUnits))
        if let last = units.last, (0xD800...0xDBFF).contains(last) {
            units.removeLast()
        }
        return String(decoding: units, as: UTF16.self)
    }
}

public enum SetupAsyncState: String, Equatable, Sendable {
    case idle
    case working
    case passed
    case failed
}

public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general
    case audio
    case output
    case agent
    case privacy

    public var id: String { rawValue }
}

public enum OnboardingAgentChoice: String, Codable, Sendable {
    case agent
    case transcript
}

public enum OnboardingAudioSource: String, CaseIterable, Sendable {
    case system
    case microphone
}

public struct OnboardingAudioSourceState: Equatable, Sendable {
    public var state: SetupAsyncState
    public var result: AudioSourceCheck?
    public var error: String?
    public var restartRequired: Bool

    public init(
        state: SetupAsyncState = .idle,
        result: AudioSourceCheck? = nil,
        error: String? = nil,
        restartRequired: Bool = false
    ) {
        self.state = state
        self.result = result
        self.error = error
        self.restartRequired = restartRequired
    }
}

public struct OnboardingDraftState: Codable, Equatable, Sendable {
    public var version: Int
    public var step: Int
    public var furthestStep: Int
    public var agentChoice: OnboardingAgentChoice
    public var primary: ProviderID?
    public var secondary: ProviderID?
    public var testedProvider: ProviderID?
    public var transcriptionConfiguration: TranscriptionConfiguration
    public var audioMode: AudioMode
    public var listeningShortcut: ListeningShortcut?

    public init(
        version: Int = 1,
        step: Int,
        furthestStep: Int,
        agentChoice: OnboardingAgentChoice,
        primary: ProviderID?,
        secondary: ProviderID?,
        testedProvider: ProviderID?,
        transcriptionConfiguration: TranscriptionConfiguration,
        audioMode: AudioMode = .both,
        listeningShortcut: ListeningShortcut?
    ) {
        self.version = version
        self.step = min(5, max(1, step))
        self.furthestStep = min(5, max(self.step, furthestStep))
        self.agentChoice = agentChoice
        self.primary = primary
        self.secondary = secondary
        self.testedProvider = testedProvider
        self.transcriptionConfiguration = transcriptionConfiguration
        self.audioMode = audioMode
        self.listeningShortcut = listeningShortcut
    }
}

public struct OnboardingResult: Equatable, Sendable {
    public var providerConfiguration: ProviderConfiguration
    public var transcriptionConfiguration: TranscriptionConfiguration
    public var audioMode: AudioMode
    public var startListening: Bool

    public init(
        providerConfiguration: ProviderConfiguration,
        transcriptionConfiguration: TranscriptionConfiguration,
        audioMode: AudioMode,
        startListening: Bool
    ) {
        self.providerConfiguration = providerConfiguration
        self.transcriptionConfiguration = transcriptionConfiguration
        self.audioMode = audioMode
        self.startListening = startListening
    }
}

public enum MeetingOutputRuleKey: String, CaseIterable, Identifiable, Sendable {
    case title
    case summary
    public var id: String { rawValue }
}

public let arcoDefaultTitlePrompt = """
Create a concise, specific title for this meeting.
Use the main topic, decision, or outcome.
Write in the transcript's primary language and keep it under 8 words or 16 CJK characters.
Do not include dates, speaker labels, or words such as "meeting".
Return only the title.
"""

public let arcoDefaultSummaryPrompt = """
Create a concise end-of-meeting note in the transcript's primary language.
Start with the outcome, then capture key decisions, unresolved questions, and action items.
Do not invent owners, commitments, or deadlines.
Leave out sections that were not discussed.
Ground every point in the transcript.
"""

public let arcoMaximumGenerationPromptCharacters = 8_000

public struct LocalModelDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var detailKey: String
    public var downloadSize: String?

    public init(id: String, label: String, detailKey: String, downloadSize: String? = nil) {
        self.id = id
        self.label = label
        self.detailKey = detailKey
        self.downloadSize = downloadSize
    }
}

public let arcoLocalASRModels: [LocalModelDescriptor] = [
    .init(id: "nemotron-speech-3.5-streaming", label: "Nemotron Speech 3.5", detailKey: "model.nemotron", downloadSize: "~670 MB"),
    .init(id: "whisper-tiny", label: "Whisper Tiny", detailKey: "model.whisperTiny", downloadSize: "~75 MB"),
    .init(id: "whisper-base", label: "Whisper Base", detailKey: "model.whisperBase", downloadSize: "~142 MB"),
    .init(id: "whisper-small", label: "Whisper Small", detailKey: "model.whisperSmall", downloadSize: "~466 MB"),
    .init(id: "whisper-medium", label: "Whisper Medium", detailKey: "model.whisperMedium", downloadSize: "~1.5 GB"),
    .init(id: "whisper-large", label: "Whisper Large", detailKey: "model.whisperLarge", downloadSize: "~2.9 GB"),
]

public let arcoLocalDiarizationModels: [LocalModelDescriptor] = [
    .init(id: "sortformer-streaming", label: "Streaming Sortformer", detailKey: "settings.sortformerDescription"),
    .init(id: "pyannote-wespeaker-streaming", label: "Pyannote + WeSpeaker", detailKey: "settings.pyannoteStreamingDescription"),
    .init(id: "lseend-ami-streaming", label: "LS-EEND Meeting", detailKey: "settings.lseendMeetingDescription"),
    .init(id: "lseend-dihard3-streaming", label: "LS-EEND General", detailKey: "settings.lseendGeneralDescription"),
]

public struct NoteDraft: Equatable, Sendable {
    public var id: String?
    public var title: String
    public var body: String
    public var source: String
    public var meetingId: String?
    public var meetingTitle: String?
    public var updatedAt: String?

    public init(
        id: String?,
        title: String,
        body: String,
        source: String,
        meetingId: String?,
        meetingTitle: String?,
        updatedAt: String?
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.source = source
        self.meetingId = meetingId
        self.meetingTitle = meetingTitle
        self.updatedAt = updatedAt
    }

    public init(note: NoteDocument) {
        self.init(
            id: note.id,
            title: note.title,
            body: note.body,
            source: note.source,
            meetingId: note.meetingId,
            meetingTitle: note.meetingTitle,
            updatedAt: note.updatedAt
        )
    }

    public static func empty(meetingId: String?) -> NoteDraft {
        NoteDraft(
            id: nil,
            title: "",
            body: "",
            source: "manual",
            meetingId: meetingId,
            meetingTitle: nil,
            updatedAt: nil
        )
    }

    public func hasSamePersistedContent(as other: NoteDraft) -> Bool {
        id == other.id
            && title == other.title
            && body == other.body
            && meetingId == other.meetingId
    }
}

public enum NotesEditorMode: String, CaseIterable, Sendable {
    case write
    case preview
}

public enum NotesFormattingAction: String, CaseIterable, Identifiable, Sendable {
    case title
    case heading
    case subheading
    case body
    case monostyled
    case bold
    case italic
    case strikethrough
    case bullet
    case dash
    case numbered
    case checklist
    case quote
    case table
    case code

    public var id: String { rawValue }
}

public struct ShortcutKeyEvent: Equatable, Sendable {
    public var key: String
    public var code: String
    public var command: Bool
    public var control: Bool
    public var option: Bool
    public var shift: Bool

    public init(
        key: String,
        code: String,
        command: Bool = false,
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false
    ) {
        self.key = key
        self.code = code
        self.command = command
        self.control = control
        self.option = option
        self.shift = shift
    }

    public var listeningShortcut: ListeningShortcut? {
        if ["Meta", "Control", "Alt", "Shift"].contains(key) { return nil }
        var modifiers: [String] = []
        if command || control { modifiers.append("CommandOrControl") }
        if option { modifiers.append("Alt") }
        if shift { modifiers.append("Shift") }
        guard !modifiers.isEmpty else { return nil }
        let normalizedCode = key == " " ? "Space" : code
        return ListeningShortcut(rawValue: (modifiers + [normalizedCode]).joined(separator: "+"))
    }
}

public extension ListeningShortcut {
    static func displayValue(_ shortcut: ListeningShortcut?) -> String {
        shortcut?.displayValue ?? "Off"
    }
}
