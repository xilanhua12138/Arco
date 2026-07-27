import Foundation

public enum AppRoute: String, Codable, CaseIterable, Sendable {
    case current
    case history
    case notes
    case review
}

public enum CapturePhase: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case error

    public var optimisticToggle: CapturePhase? {
        switch self {
        case .idle, .error: .starting
        case .recording: .stopping
        case .starting, .stopping: nil
        }
    }
}

public enum NavigationAction: Equatable, Sendable {
    case show(AppRoute)
    case openMeeting(String)
    case captureChanged(CapturePhase, activeMeetingID: String?)
}

public struct NavigationState: Equatable, Sendable {
    public var route: AppRoute
    public var selectedMeetingID: String?
    public var activeMeetingID: String?
    public var capturePhase: CapturePhase

    public init(
        route: AppRoute = .current,
        selectedMeetingID: String? = nil,
        activeMeetingID: String? = nil,
        capturePhase: CapturePhase = .idle
    ) {
        self.route = route
        self.selectedMeetingID = selectedMeetingID
        self.activeMeetingID = activeMeetingID
        self.capturePhase = capturePhase
    }

    public var isReviewingWhileRecording: Bool {
        capturePhase == .recording
            && activeMeetingID != nil
            && selectedMeetingID != activeMeetingID
    }

    public mutating func reduce(_ action: NavigationAction) {
        switch action {
        case let .show(next):
            route = next
            if next == .current, capturePhase == .recording, let activeMeetingID {
                selectedMeetingID = activeMeetingID
            }
        case let .openMeeting(id):
            selectedMeetingID = id
            route = id == activeMeetingID ? .current : .review
        case let .captureChanged(phase, activeID):
            capturePhase = phase
            activeMeetingID = activeID
            if phase == .recording, route == .current, let activeID {
                selectedMeetingID = activeID
            }
        }
    }
}

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: Self { self }
    public var displayName: String { self == .codex ? "Codex" : "Claude" }
    public var runtimeName: String { self == .codex ? "Codex CLI" : "Claude Code" }
}

public struct RuntimeStatus: Codable, Equatable, Identifiable, Sendable {
    public var provider: ProviderID
    public var label: String
    public var available: Bool
    public var path: String?
    public var version: String?
    public var id: ProviderID { provider }

    public init(provider: ProviderID, label: String, available: Bool, path: String?, version: String?) {
        self.provider = provider
        self.label = label
        self.available = available
        self.path = path
        self.version = version
    }
}

public struct ProviderConnectionTest: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var ok: Bool
    public var message: String
}

public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public var setupComplete: Bool
    public var primary: ProviderID?
    public var secondary: ProviderID?

    public init(setupComplete: Bool = false, primary: ProviderID? = nil, secondary: ProviderID? = nil) {
        self.setupComplete = setupComplete
        self.primary = primary
        self.secondary = secondary
    }

    public var isValid: Bool {
        if setupComplete { return primary != nil && primary != secondary }
        return primary == nil && secondary == nil
    }
}

public struct ProviderRoute: Equatable, Sendable {
    public var provider: ProviderID?
    public var available: Bool
    public var isFailover: Bool

    public static func resolve(
        config: ProviderConfiguration,
        runtimes: [RuntimeStatus]
    ) -> ProviderRoute {
        guard config.setupComplete, let primary = config.primary else {
            return ProviderRoute(provider: nil, available: false, isFailover: false)
        }
        if runtimes.contains(where: { $0.provider == primary && $0.available }) {
            return ProviderRoute(provider: primary, available: true, isFailover: false)
        }
        if let secondary = config.secondary,
           runtimes.contains(where: { $0.provider == secondary && $0.available }) {
            return ProviderRoute(provider: secondary, available: true, isFailover: true)
        }
        return ProviderRoute(provider: primary, available: false, isFailover: false)
    }
}

public enum AudioMode: String, Codable, CaseIterable, Sendable {
    case both
    case system
    case mic
}

public enum TranscriptionProvider: String, Codable, CaseIterable, Sendable {
    case deepgram
    case elevenlabs
    case doubao
    case local
}

public enum DiarizationProvider: String, Codable, CaseIterable, Sendable {
    case deepgram
    case doubao
    case local
    case none
}

public struct ASRConfiguration: Codable, Equatable, Sendable {
    public var provider: TranscriptionProvider
    public var model: String
    public var language: String

    public init(provider: TranscriptionProvider, model: String, language: String) {
        self.provider = provider
        self.model = model
        self.language = language
    }
}

public struct DiarizationConfiguration: Codable, Equatable, Sendable {
    public var provider: DiarizationProvider
    public var model: String?

    public init(provider: DiarizationProvider, model: String?) {
        self.provider = provider
        self.model = model
    }
}

public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    public var asr: ASRConfiguration
    public var diarization: DiarizationConfiguration

    public init(asr: ASRConfiguration, diarization: DiarizationConfiguration) {
        self.asr = asr
        self.diarization = diarization
    }

    public static let `default` = TranscriptionConfiguration(
        asr: ASRConfiguration(provider: .deepgram, model: "nova-3", language: "zh-CN"),
        diarization: DiarizationConfiguration(provider: .deepgram, model: "latest")
    )

    public var isValid: Bool {
        guard ["auto", "zh-CN", "en-US"].contains(asr.language) else { return false }
        let asrValid = switch asr.provider {
        case .deepgram: asr.model == "nova-3"
        case .elevenlabs: asr.model == "scribe-v2-realtime"
        case .doubao: asr.model == "bigmodel"
        case .local: Self.localASRModels.contains(asr.model)
        }
        guard asrValid else { return false }
        return switch diarization.provider {
        case .deepgram: diarization.model == "latest"
        case .doubao: diarization.model == "bigmodel"
        case .local: diarization.model.map(Self.localDiarizationModels.contains) == true
        case .none: diarization.model == nil
        }
    }

    public static let localASRModels: Set<String> = [
        "nemotron-speech-3.5-streaming", "whisper-tiny", "whisper-base",
        "whisper-small", "whisper-medium", "whisper-large",
    ]
    public static let localDiarizationModels: Set<String> = [
        "sortformer-streaming", "pyannote-wespeaker-streaming",
        "lseend-ami-streaming", "lseend-dihard3-streaming",
    ]
}

public struct ListeningShortcut: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let parts = rawValue
            .split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2, let key = parts.last else { return nil }
        let modifiers = Array(parts.dropLast())
        let allowedModifiers = Set(["CommandOrControl", "Control", "Alt", "Shift"])
        guard modifiers.allSatisfy(allowedModifiers.contains), Set(modifiers).count == modifiers.count else { return nil }
        let keyPattern = #"^(?:Space|Enter|Tab|Backspace|Escape|Arrow(?:Up|Down|Left|Right)|Key[A-Z]|Digit[0-9]|F(?:[1-9]|1[0-2]))$"#
        guard key.range(of: keyPattern, options: .regularExpression) != nil else { return nil }
        self.rawValue = rawValue
    }

    public static let `default` = ListeningShortcut(rawValue: "CommandOrControl+Shift+Space")!

    public var displayValue: String {
        let labels = ["CommandOrControl": "⌘", "Control": "⌃", "Alt": "⌥", "Shift": "⇧"]
        let parts = rawValue.split(separator: "+").map(String.init)
        let modifiers = parts.dropLast().map { labels[$0] ?? $0 }
        let rawKey = parts.last ?? ""
        let key = rawKey
            .replacingOccurrences(of: "Key", with: "")
            .replacingOccurrences(of: "Digit", with: "")
            .replacingOccurrences(of: "ArrowUp", with: "↑")
            .replacingOccurrences(of: "ArrowDown", with: "↓")
            .replacingOccurrences(of: "ArrowLeft", with: "←")
            .replacingOccurrences(of: "ArrowRight", with: "→")
        return (modifiers + [key]).joined(separator: " ")
    }
}

public struct MeetingSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String?
    public var generatedSummary: String?
    public var titleGenerationStatus: String
    public var summaryGenerationStatus: String
    public var startedAt: String
    public var durationLabel: String
    public var preview: String
    public var path: String
    public var utteranceCount: Int
    public var isLive: Bool
    public var source: String

    public init(
        id: String,
        title: String?,
        generatedSummary: String?,
        titleGenerationStatus: String,
        summaryGenerationStatus: String,
        startedAt: String,
        durationLabel: String,
        preview: String,
        path: String,
        utteranceCount: Int,
        isLive: Bool,
        source: String
    ) {
        self.id = id
        self.title = title
        self.generatedSummary = generatedSummary
        self.titleGenerationStatus = titleGenerationStatus
        self.summaryGenerationStatus = summaryGenerationStatus
        self.startedAt = startedAt
        self.durationLabel = durationLabel
        self.preview = preview
        self.path = path
        self.utteranceCount = utteranceCount
        self.isLive = isLive
        self.source = source
    }

    public var displayTitle: String { title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled meeting" }
}

public struct TranscriptLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var timestamp: String
    public var speaker: String
    public var text: String
    public var sequence: Int

    public init(id: String, timestamp: String, speaker: String, text: String, sequence: Int) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
        self.sequence = sequence
    }
}

public struct MeetingDetail: Codable, Equatable, Sendable {
    public var summary: MeetingSummary
    public var lines: [TranscriptLine]
    public var rawMarkdown: String

    public init(summary: MeetingSummary, lines: [TranscriptLine], rawMarkdown: String) {
        self.summary = summary
        self.lines = lines
        self.rawMarkdown = rawMarkdown
    }
}

public struct LiveMeetingPoll: Codable, Equatable, Sendable {
    public var capture: CaptureState
    public var revision: String?
    public var meeting: MeetingDetail?

    public init(capture: CaptureState, revision: String?, meeting: MeetingDetail?) {
        self.capture = capture
        self.revision = revision
        self.meeting = meeting
    }
}

public struct CaptureState: Codable, Equatable, Sendable {
    public var phase: CapturePhase
    public var activeMeetingId: String?
    public var startedAt: String?
    public var message: String?
    public var mode: AudioMode?
    public var transcriptPath: String?
    public var error: String?
    public var transcription: TranscriptionConfiguration?

    public init(
        phase: CapturePhase,
        activeMeetingId: String?,
        startedAt: String?,
        message: String?,
        mode: AudioMode?,
        transcriptPath: String?,
        error: String?,
        transcription: TranscriptionConfiguration?
    ) {
        self.phase = phase
        self.activeMeetingId = activeMeetingId
        self.startedAt = startedAt
        self.message = message
        self.mode = mode
        self.transcriptPath = transcriptPath
        self.error = error
        self.transcription = transcription
    }

    public static let idle = CaptureState(
        phase: .idle,
        activeMeetingId: nil,
        startedAt: nil,
        message: nil,
        mode: nil,
        transcriptPath: nil,
        error: nil,
        transcription: nil
    )
}

public struct StorageSettings: Codable, Equatable, Sendable {
    public var defaultDirectory: String
    public var selectedDirectory: String
    public var usingDefault: Bool

    public init(defaultDirectory: String, selectedDirectory: String, usingDefault: Bool) {
        self.defaultDirectory = defaultDirectory
        self.selectedDirectory = selectedDirectory
        self.usingDefault = usingDefault
    }
}

public struct CredentialStatus: Codable, Equatable, Sendable {
    public var configured: Bool
    public var verified: Bool
    public var message: String?

    public static let missing = CredentialStatus(configured: false, verified: false, message: nil)
}

public struct DoubaoCredentialStatus: Codable, Equatable, Sendable {
    public var configured: Bool
    public var verified: Bool
    public var message: String?

    public static let missing = DoubaoCredentialStatus(configured: false, verified: false, message: nil)
}

public struct AudioSourceCheck: Codable, Equatable, Sendable {
    public var required: Bool
    public var ready: Bool
    public var level: Double?
    public var message: String?
}

public struct AudioSetupCheck: Codable, Equatable, Sendable {
    public var mode: AudioMode
    public var success: Bool
    public var system: AudioSourceCheck
    public var microphone: AudioSourceCheck
}

public struct TranscriptionModelStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var installed: Bool
    public var phase: String
    public var progress: Double?
    public var error: String?
    public var path: String?

    public init(
        id: String,
        installed: Bool,
        phase: String,
        progress: Double?,
        error: String?,
        path: String?
    ) {
        self.id = id
        self.installed = installed
        self.phase = phase
        self.progress = progress
        self.error = error
        self.path = path
    }
}

public struct AgentSource: Codable, Equatable, Identifiable, Sendable {
    public var kind: String
    public var label: String
    public var reference: String
    public var id: String { "\(kind):\(reference)" }
}

public struct MeetingAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var meetingId: String
    public var name: String
    public var text: String
    public var addedAt: String
}

public struct AgentToolActivity: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var name: String
    public var status: String
    public var detail: String?
    public var output: String?

    public init(
        id: String,
        kind: String,
        name: String,
        status: String,
        detail: String?,
        output: String?
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.status = status
        self.detail = detail
        self.output = output
    }
}

public struct AgentTurn: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var meetingId: String
    public var provider: ProviderID
    public var question: String
    public var answer: String
    public var sources: [AgentSource]
    public var toolActivities: [AgentToolActivity]
    public var workDurationMs: UInt64?
    public var contextScope: String
    public var createdAt: String
    public var savedAsNote: Bool
    public var noteId: String?
    public var usedFallback: Bool
    public var providerSessionId: String?
    public var providerTurnId: String?

    public init(
        id: String,
        meetingId: String,
        provider: ProviderID,
        question: String,
        answer: String,
        sources: [AgentSource],
        contextScope: String,
        createdAt: String,
        savedAsNote: Bool,
        noteId: String?,
        usedFallback: Bool,
        providerSessionId: String?,
        providerTurnId: String?,
        toolActivities: [AgentToolActivity] = [],
        workDurationMs: UInt64? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.provider = provider
        self.question = question
        self.answer = answer
        self.sources = sources
        self.toolActivities = toolActivities
        self.workDurationMs = workDurationMs
        self.contextScope = contextScope
        self.createdAt = createdAt
        self.savedAsNote = savedAsNote
        self.noteId = noteId
        self.usedFallback = usedFallback
        self.providerSessionId = providerSessionId
        self.providerTurnId = providerTurnId
    }

    private enum CodingKeys: String, CodingKey {
        case id, meetingId, provider, question, answer, sources, toolActivities, workDurationMs, contextScope
        case createdAt, savedAsNote, noteId, usedFallback, providerSessionId, providerTurnId
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        meetingId = try values.decode(String.self, forKey: .meetingId)
        provider = try values.decode(ProviderID.self, forKey: .provider)
        question = try values.decode(String.self, forKey: .question)
        answer = try values.decode(String.self, forKey: .answer)
        sources = try values.decode([AgentSource].self, forKey: .sources)
        toolActivities = try values.decodeIfPresent([AgentToolActivity].self, forKey: .toolActivities) ?? []
        workDurationMs = try values.decodeIfPresent(UInt64.self, forKey: .workDurationMs)
        contextScope = try values.decode(String.self, forKey: .contextScope)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        savedAsNote = try values.decode(Bool.self, forKey: .savedAsNote)
        noteId = try values.decodeIfPresent(String.self, forKey: .noteId)
        usedFallback = try values.decodeIfPresent(Bool.self, forKey: .usedFallback) ?? false
        providerSessionId = try values.decodeIfPresent(String.self, forKey: .providerSessionId)
        providerTurnId = try values.decodeIfPresent(String.self, forKey: .providerTurnId)
    }
}

public struct AgentStreamEvent: Codable, Equatable, Sendable {
    public var type: String
    public var requestId: String
    public var meetingId: String
    public var phase: String?
    public var answer: String?
    public var tool: AgentToolActivity?

    public init(
        type: String,
        requestId: String,
        meetingId: String,
        phase: String?,
        answer: String?,
        tool: AgentToolActivity? = nil
    ) {
        self.type = type
        self.requestId = requestId
        self.meetingId = meetingId
        self.phase = phase
        self.answer = answer
        self.tool = tool
    }
}

public struct AgentStreamingTurn: Equatable, Sendable {
    public var requestId: String
    public var meetingId: String
    public var question: String
    public var phase: String
    public var answer: String
    public var toolActivities: [AgentToolActivity] = []
    public var startedAt: Date
}

public struct AskAgentInput: Equatable, Sendable {
    public var provider: ProviderID
    public var usedFallback: Bool
    public var question: String
    public var agentPrompt: String?
    public var meetingId: String
    public var workspace: String?
    public var contextScope: String

    public init(
        provider: ProviderID,
        usedFallback: Bool,
        question: String,
        agentPrompt: String? = nil,
        meetingId: String,
        workspace: String? = nil,
        contextScope: String
    ) {
        self.provider = provider
        self.usedFallback = usedFallback
        self.question = question
        self.agentPrompt = agentPrompt
        self.meetingId = meetingId
        self.workspace = workspace
        self.contextScope = contextScope
    }
}

public struct NoteDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var source: String
    public var createdAt: String
    public var updatedAt: String
    public var path: String
    public var meetingId: String?
    public var meetingTitle: String?
    public var agentTurnId: String?

    public init(
        id: String,
        title: String,
        body: String,
        source: String,
        createdAt: String,
        updatedAt: String,
        path: String,
        meetingId: String?,
        meetingTitle: String?,
        agentTurnId: String?
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.path = path
        self.meetingId = meetingId
        self.meetingTitle = meetingTitle
        self.agentTurnId = agentTurnId
    }
}

public struct SaveNoteInput: Equatable, Sendable {
    public var id: String?
    public var meetingId: String
    public var title: String
    public var body: String

    public init(id: String?, meetingId: String, title: String, body: String) {
        self.id = id
        self.meetingId = meetingId
        self.title = title
        self.body = body
    }
}

public enum MeetingOutputKind: String, Codable, CaseIterable, Sendable {
    case title
    case summary
}

public struct MeetingOutputArtifact: Codable, Equatable, Sendable {
    public var kind: String
    public var status: String
    public var value: String?
    public var provider: ProviderID?
    public var providerSessionId: String?
    public var providerTurnId: String?
    public var error: String?
    public var updatedAt: String

    public init(
        kind: String,
        status: String,
        value: String?,
        provider: ProviderID?,
        providerSessionId: String?,
        providerTurnId: String?,
        error: String?,
        updatedAt: String
    ) {
        self.kind = kind
        self.status = status
        self.value = value
        self.provider = provider
        self.providerSessionId = providerSessionId
        self.providerTurnId = providerTurnId
        self.error = error
        self.updatedAt = updatedAt
    }
}

public struct GenerationRule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var promptOverride: String?
}

public struct GenerationSettings: Codable, Equatable, Sendable {
    public var title: GenerationRule
    public var summary: GenerationRule

    public static let `default` = GenerationSettings(
        title: GenerationRule(enabled: true, promptOverride: nil),
        summary: GenerationRule(enabled: true, promptOverride: nil)
    )
}

public extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
