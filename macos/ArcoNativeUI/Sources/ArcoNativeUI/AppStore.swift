import Foundation
import Observation

@MainActor
public protocol CaptureSurfaceCoordinating: AnyObject {
    func showCaptureHUD() throws
    func releaseCaptureSurfaces()
}

@MainActor
public final class NoopCaptureSurfaceCoordinator: CaptureSurfaceCoordinating {
    public init() {}
    public func showCaptureHUD() throws {}
    public func releaseCaptureSurfaces() {}
}

public enum MeetingTitleRefreshPolicy {
    public static let interval: TimeInterval = 5 * 60

    public static func bucket(startedAt: String?, now: Date) -> Int? {
        guard let startedAt else { return nil }
        let standard = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        guard let start = fractional.date(from: startedAt) ?? standard.date(from: startedAt) else {
            return nil
        }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= interval else { return nil }
        return Int(elapsed / interval)
    }
}

@MainActor
@Observable
public final class ArcoStore {
    public private(set) var meetings: [MeetingSummary] = []
    public private(set) var activeMeeting: MeetingSummary?
    public private(set) var selectedMeetingId: String?
    public private(set) var meeting: MeetingDetail?
    public private(set) var runtimes: [RuntimeStatus] = []
    public private(set) var capture: CaptureState = .idle
    public private(set) var completedMeetingId: String?
    public private(set) var agentTurnsByMeeting: [String: [AgentTurn]] = [:]
    public private(set) var attachmentsByMeeting: [String: [MeetingAttachment]] = [:]
    public private(set) var savedNotes: [NoteDocument] = []
    public private(set) var notesLoading = false
    public private(set) var lastSuccessfulNotesQuery: String?
    public private(set) var loading = true
    public private(set) var agentRunning = false
    public private(set) var agentStreamingTurn: AgentStreamingTurn?
    public private(set) var error: String?

    public private(set) var storageSettings: StorageSettings?
    public private(set) var notesStorageSettings: StorageSettings?
    public private(set) var storageChanging = false
    public private(set) var notesStorageChanging = false
    public private(set) var storageError: String?

    public private(set) var transcriptionModels: [TranscriptionModelStatus] = []
    public private(set) var deepgramCredential: CredentialStatus = .missing
    public private(set) var elevenLabsCredential: CredentialStatus = .missing
    public private(set) var doubaoCredential: DoubaoCredentialStatus = .missing
    public private(set) var deepgramCredentialBusy = false
    public private(set) var elevenLabsCredentialBusy = false
    public private(set) var doubaoCredentialBusy = false

    public var agentReplies: [AgentTurn] {
        selectedMeetingId.flatMap { agentTurnsByMeeting[$0] } ?? []
    }

    public func attachments(for meetingId: String) -> [MeetingAttachment] {
        attachmentsByMeeting[meetingId] ?? []
    }

    public let isDesktop = true

    private let backend: any BackendDispatching
    private let captureSurfaces: any CaptureSurfaceCoordinating
    private let translate: ArcoTranslate
    private let loadProviderConfiguration: @MainActor () -> ProviderConfiguration
    private let loadGenerationSettings: @MainActor () -> GenerationSettings
    private let now: @MainActor () -> Date

    private var selectedReference: String?
    private var activeCaptureReference: String?
    private var meetingReference: MeetingDetail?
    private var liveMeetingReference: MeetingDetail?
    private var meetingQuery = ""
    private var noteQuery = ""
    private var noteRequest = 0
    private var selectionRequest = 0
    private struct GenerationClaim {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var generationClaims: [String: GenerationClaim] = [:]
    private var liveTitleRefreshBuckets: [String: Int] = [:]
    private var liveMeetingRevisions: [String: String] = [:]
    private var pollTask: Task<Void, Never>?
    private var disposed = false

    private enum PreferredActiveMeeting {
        case current
        case explicit(String?)
    }

    public init(
        backend: any BackendDispatching,
        captureSurfaces: any CaptureSurfaceCoordinating = NoopCaptureSurfaceCoordinator(),
        translate: @escaping ArcoTranslate = { key, _ in key },
        loadProviderConfiguration: @escaping @MainActor () -> ProviderConfiguration = {
            ProviderConfiguration()
        },
        loadGenerationSettings: @escaping @MainActor () -> GenerationSettings = {
            .default
        },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.backend = backend
        self.captureSurfaces = captureSurfaces
        self.translate = translate
        self.loadProviderConfiguration = loadProviderConfiguration
        self.loadGenerationSettings = loadGenerationSettings
        self.now = now
        backend.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handle(event)
            }
        }
    }

    deinit {
        backend.setEventHandler(nil)
    }

    public func initialize() async {
        loading = true
        defer { loading = false }
        do {
            async let nextMeetings: [MeetingSummary] = backend.call("list_meetings")
            async let nextRuntimes: [RuntimeStatus] = backend.call("runtime_status")
            async let nextCapture: CaptureState = backend.call("capture_status")
            let (loadedMeetings, loadedRuntimes, loadedCapture) = try await (
                nextMeetings, nextRuntimes, nextCapture
            )
            guard !disposed else { return }
            meetings = loadedMeetings
            runtimes = loadedRuntimes
            applyCapture(loadedCapture)
            activeMeeting = loadedCapture.activeMeetingId.flatMap { id in
                loadedMeetings.first { $0.id == id }
            }
            if let firstId = loadedCapture.activeMeetingId ?? loadedMeetings.first?.id {
                _ = await selectMeeting(firstId)
            }
        } catch {
            guard !disposed else { return }
            self.error = errorMessage(error, fallbackKey: "error.startArco")
        }
        await loadStorageSettings()
    }

    public func dispose() {
        disposed = true
        pollTask?.cancel()
        pollTask = nil
        backend.setEventHandler(nil)
    }

    @discardableResult
    public func selectMeeting(_ id: String) async -> Bool {
        selectionRequest += 1
        let request = selectionRequest
        error = nil
        do {
            let next: MeetingDetail = try await backend.call(
                "read_meeting",
                arguments: ["id": .string(id)]
            )
            var turns: [AgentTurn] = []
            var threadError: String?
            do {
                turns = try await backend.call(
                    "list_agent_turns",
                    arguments: ["meetingId": .string(id)]
                )
            } catch {
                threadError = errorMessage(error, fallbackKey: "error.loadAgentThread")
            }
            var attachments: [MeetingAttachment] = []
            do {
                attachments = try await backend.call(
                    "list_attachments",
                    arguments: ["meetingId": .string(id)]
                )
            } catch {
                attachments = []
            }
            guard selectionRequest == request else { return false }
            selectedReference = id
            meetingReference = next
            if id == activeCaptureReference {
                liveMeetingReference = next
            }
            selectedMeetingId = id
            meeting = next
            agentTurnsByMeeting[id] = turns
            attachmentsByMeeting[id] = attachments
            if let threadError { self.error = threadError }
            triggerLiveTitleGenerationIfNeeded()
            return true
        } catch {
            if selectionRequest == request {
                self.error = errorMessage(error, fallbackKey: "error.openMeeting")
            }
            return false
        }
    }

    public func refreshMeetings(_ query: String = "") async {
        await refreshMeetings(query, preferredActive: .current)
    }

    @discardableResult
    public func refreshAgentTurns(_ meetingId: String) async -> [AgentTurn] {
        do {
            let turns: [AgentTurn] = try await backend.call(
                "list_agent_turns",
                arguments: ["meetingId": .string(meetingId)]
            )
            agentTurnsByMeeting[meetingId] = turns
            return turns
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.refreshAgentThread")
            return []
        }
    }

    @discardableResult
    public func refreshAttachments(_ meetingId: String) async -> [MeetingAttachment] {
        do {
            let attachments: [MeetingAttachment] = try await backend.call(
                "list_attachments",
                arguments: ["meetingId": .string(meetingId)]
            )
            attachmentsByMeeting[meetingId] = attachments
            return attachments
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.refreshAttachments")
            return []
        }
    }

    @discardableResult
    public func addAttachment(meetingId: String, name: String, text: String) async -> Bool {
        error = nil
        do {
            let attachments: [MeetingAttachment] = try await backend.call(
                "add_attachment",
                arguments: [
                    "meetingId": .string(meetingId),
                    "name": .string(name),
                    "text": .string(text),
                ]
            )
            attachmentsByMeeting[meetingId] = attachments
            return true
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.addAttachment")
            return false
        }
    }

    @discardableResult
    public func removeAttachment(meetingId: String, attachmentId: String) async -> Bool {
        error = nil
        do {
            let attachments: [MeetingAttachment] = try await backend.call(
                "remove_attachment",
                arguments: [
                    "meetingId": .string(meetingId),
                    "attachmentId": .string(attachmentId),
                ]
            )
            attachmentsByMeeting[meetingId] = attachments
            return true
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.removeAttachment")
            return false
        }
    }

    @discardableResult
    public func refreshSavedNotes(_ query: String = "") async -> [NoteDocument] {
        noteRequest += 1
        let request = noteRequest
        noteQuery = query
        notesLoading = true
        defer {
            if noteRequest == request { notesLoading = false }
        }
        do {
            let notes: [NoteDocument] = try await backend.call(
                "list_notes",
                arguments: ["query": .string(query)]
            )
            if noteRequest == request {
                savedNotes = notes
                lastSuccessfulNotesQuery = query
            }
            return notes
        } catch {
            if noteRequest == request {
                self.error = errorMessage(error, fallbackKey: "error.loadSavedNotes")
            }
            return []
        }
    }

    @discardableResult
    public func renameMeeting(_ meetingId: String, title: String?) async -> Bool {
        error = nil
        do {
            let updated: MeetingSummary = try await backend.call(
                "rename_meeting",
                arguments: [
                    "meetingId": .string(meetingId),
                    "title": title.map(AnySendable.string) ?? .null,
                ]
            )
            meetings = meetings.map { $0.id == meetingId ? updated : $0 }
            if activeMeeting?.id == meetingId { activeMeeting = updated }
            if meetingReference?.summary.id == meetingId, var next = meetingReference {
                next.summary = updated
                meetingReference = next
                meeting = next
            }
            return true
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.renameMeeting")
            return false
        }
    }

    @discardableResult
    public func syncCapture() async -> CaptureState? {
        do {
            let previousActiveId = activeCaptureReference
            let next: CaptureState = try await backend.call("capture_status")
            applyCapture(next)
            await refreshMeetings("", preferredActive: .explicit(next.activeMeetingId))
            if next.activeMeetingId != nil { completedMeetingId = nil }
            if let previousActiveId, next.activeMeetingId == nil {
                let opened = await selectMeeting(previousActiveId)
                if opened, meetingReference?.summary.id == previousActiveId,
                   let completed = meetingReference {
                    completedMeetingId = previousActiveId
                    Task { @MainActor [weak self] in
                        await self?.generateStoppedMeetingOutputs(completed)
                    }
                }
            }
            synchronizeCaptureSurfaces(with: next)
            return next
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.refreshRecording")
            return nil
        }
    }

    @discardableResult
    public func toggleCapture(
        mode: AudioMode = .both,
        transcription: TranscriptionConfiguration? = nil,
        resumeMeetingId: String? = nil
    ) async -> CaptureState? {
        guard capture.phase != .starting, capture.phase != .stopping else { return nil }
        error = nil
        let stopping = capture.phase == .recording
        let stoppedMeetingId = stopping ? capture.activeMeetingId : nil
        if !stopping { completedMeetingId = nil }
        var optimistic = capture
        optimistic.phase = stopping ? .stopping : .starting
        applyCapture(optimistic)
        do {
            let next: CaptureState
            if stopping {
                defer { captureSurfaces.releaseCaptureSurfaces() }
                next = try await backend.call("stop_capture")
            } else {
                do {
                    // Present the owned HUD in the initiating click turn. Cloud
                    // provider setup can take long enough that waiting for the
                    // backend response makes the first click look lost.
                    try captureSurfaces.showCaptureHUD()
                } catch let windowError {
                    throw BackendTransportError.backend(
                        "recording HUD could not open; capture was not started: \(windowError.localizedDescription)"
                    )
                }
                var arguments: [String: AnySendable] = ["mode": .string(mode.rawValue)]
                arguments["transcription"] = try transcription.map(AnySendable.encodable) ?? .null
                arguments["meetingId"] = resumeMeetingId.map(AnySendable.string) ?? .null
                next = try await backend.call("start_capture", arguments: arguments)
            }
            applyCapture(next)
            await refreshMeetings(
                "",
                preferredActive: .explicit(stopping ? nil : next.activeMeetingId)
            )
            if let stoppedMeetingId {
                let opened = await selectMeeting(stoppedMeetingId)
                if opened, meetingReference?.summary.id == stoppedMeetingId,
                   let completed = meetingReference {
                    completedMeetingId = stoppedMeetingId
                    Task { @MainActor [weak self] in
                        await self?.generateStoppedMeetingOutputs(completed)
                    }
                }
            }
            return next
        } catch {
            if !stopping {
                captureSurfaces.releaseCaptureSurfaces()
            }
            let message = errorMessage(error, fallbackKey: "error.captureFailed")
            var failed = capture
            failed.phase = .error
            failed.message = message
            applyCapture(failed)
            self.error = message
            return nil
        }
    }

    @discardableResult
    public func refreshRuntimes() async -> [RuntimeStatus] {
        error = nil
        do {
            let next: [RuntimeStatus] = try await backend.call("runtime_status")
            runtimes = next
            return next
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.checkRuntimes")
            return []
        }
    }

    @discardableResult
    public func askAgent(_ input: AskAgentInput) async -> Bool {
        let question = input.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !agentRunning else { return false }
        let requestId = UUID().uuidString.lowercased()
        agentRunning = true
        agentStreamingTurn = AgentStreamingTurn(
            requestId: requestId,
            meetingId: input.meetingId,
            question: question,
            phase: "starting",
            answer: "",
            toolActivities: [],
            startedAt: Date()
        )
        error = nil
        defer {
            agentRunning = false
            if agentStreamingTurn?.requestId == requestId { agentStreamingTurn = nil }
        }
        do {
            let reply: AgentTurn = try await backend.call(
                "run_agent",
                arguments: [
                    "provider": .string(input.provider.rawValue),
                    "usedFallback": .bool(input.usedFallback),
                    "question": .string(question),
                    "agentPrompt": input.agentPrompt.map(AnySendable.string) ?? .null,
                    "meetingId": .string(input.meetingId),
                    "contextScope": .string(input.contextScope),
                    "workspace": input.workspace.map(AnySendable.string) ?? .null,
                    "requestId": .string(requestId),
                ]
            )
            agentTurnsByMeeting[input.meetingId, default: []].append(reply)
            return true
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.agentAnswer")
            return false
        }
    }

    @discardableResult
    public func setAgentTurnSaved(
        meetingId: String,
        turnId: String,
        saved: Bool
    ) async -> Bool {
        error = nil
        do {
            let updated: AgentTurn = try await backend.call(
                "set_agent_turn_saved",
                arguments: [
                    "meetingId": .string(meetingId),
                    "turnId": .string(turnId),
                    "saved": .bool(saved),
                ]
            )
            agentTurnsByMeeting[meetingId] = (agentTurnsByMeeting[meetingId] ?? []).map {
                $0.id == turnId ? updated : $0
            }
            _ = await refreshSavedNotes(noteQuery)
            return true
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.updateSavedNote")
            return false
        }
    }

    @discardableResult
    public func saveNote(_ input: SaveNoteInput) async -> NoteDocument? {
        error = nil
        do {
            let note: NoteDocument = try await backend.call(
                "save_note",
                arguments: [
                    "noteId": input.id.map(AnySendable.string) ?? .null,
                    "meetingId": .string(input.meetingId),
                    "title": .string(input.title),
                    "body": .string(input.body),
                ]
            )
            _ = await refreshSavedNotes(noteQuery)
            return note
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.saveNote")
            return nil
        }
    }

    @discardableResult
    public func deleteNote(_ noteId: String) async -> Bool {
        error = nil
        do {
            try await backend.callVoid(
                "delete_note",
                arguments: ["noteId": .string(noteId)]
            )
            _ = await refreshSavedNotes(noteQuery)
            return true
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.deleteNote")
            return false
        }
    }

    public func dismissError() { error = nil }
    public func dismissStorageError() { storageError = nil }

    @discardableResult
    public func loadStorageSettings() async -> StorageSettings? {
        do {
            async let transcript: StorageSettings = backend.call("storage_settings")
            async let notes: StorageSettings = backend.call("notes_storage_settings")
            let (transcriptSettings, noteSettings) = try await (transcript, notes)
            storageSettings = transcriptSettings
            notesStorageSettings = noteSettings
            return transcriptSettings
        } catch {
            storageError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func setTranscriptDirectory(_ directory: String?, query: String) async -> Bool {
        storageError = nil
        storageChanging = true
        defer { storageChanging = false }
        do {
            storageSettings = try await backend.call(
                "set_transcript_directory",
                arguments: ["directory": directory.map(AnySendable.string) ?? .null]
            )
            await refreshMeetings(query)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func setNotesDirectory(_ directory: String?, query: String) async -> Bool {
        storageError = nil
        notesStorageChanging = true
        defer { notesStorageChanging = false }
        do {
            notesStorageSettings = try await backend.call(
                "set_notes_directory",
                arguments: ["directory": directory.map(AnySendable.string) ?? .null]
            )
            _ = await refreshSavedNotes(query)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func testProvider(_ provider: ProviderID) async throws -> ProviderConnectionTest {
        try await backend.call(
            "test_agent_provider",
            arguments: ["provider": .string(provider.rawValue)]
        )
    }

    public func testAudio(_ mode: AudioMode) async throws -> AudioSetupCheck {
        try await backend.call(
            "test_audio_setup",
            arguments: ["mode": .string(mode.rawValue)]
        )
    }

    @discardableResult
    public func refreshSetupStatus() async throws -> [TranscriptionModelStatus] {
        async let models = refreshSetupTranscriptionModels()
        async let deepgram = refreshSetupDeepgramCredential()
        async let elevenLabs = refreshSetupElevenLabsCredential()
        async let doubao = refreshSetupDoubaoCredential()
        let results = await (models, deepgram, elevenLabs, doubao)

        // Match the React promises: every successful request updates its own
        // snapshot as soon as it resolves, while one failed sibling does not
        // suppress those updates. Only report an error after all four requests
        // have settled, using the stable source order for deterministic errors.
        if case let .failure(error) = results.0 { throw error }
        if case let .failure(error) = results.1 { throw error }
        if case let .failure(error) = results.2 { throw error }
        if case let .failure(error) = results.3 { throw error }

        guard case let .success(refreshedModels) = results.0 else {
            preconditionFailure("successful setup refresh must include transcription models")
        }
        return refreshedModels
    }

    private func refreshSetupTranscriptionModels() async -> Result<[TranscriptionModelStatus], any Error> {
        do {
            let models: [TranscriptionModelStatus] = try await backend.call(
                "transcription_model_status"
            )
            transcriptionModels = models
            return .success(models)
        } catch {
            // Preserve the previous model snapshot while the other setup
            // requests continue to settle independently.
            return .failure(error)
        }
    }

    private func refreshSetupDeepgramCredential() async -> Result<CredentialStatus, any Error> {
        do {
            let status: CredentialStatus = try await backend.call(
                "deepgram_credential_status"
            )
            deepgramCredential = status
            return .success(status)
        } catch {
            return .failure(error)
        }
    }

    private func refreshSetupElevenLabsCredential() async -> Result<CredentialStatus, any Error> {
        do {
            let status: CredentialStatus = try await backend.call(
                "elevenlabs_credential_status"
            )
            elevenLabsCredential = status
            return .success(status)
        } catch {
            return .failure(error)
        }
    }

    private func refreshSetupDoubaoCredential() async -> Result<DoubaoCredentialStatus, any Error> {
        do {
            let status: DoubaoCredentialStatus = try await backend.call(
                "doubao_credential_status"
            )
            doubaoCredential = status
            return .success(status)
        } catch {
            return .failure(error)
        }
    }

    public func refreshTranscriptionModels() async throws -> [TranscriptionModelStatus] {
        let models: [TranscriptionModelStatus] = try await backend.call("transcription_model_status")
        transcriptionModels = models
        return models
    }

    public func prepareTranscriptionModel(_ model: String) async throws -> [TranscriptionModelStatus] {
        let next: [TranscriptionModelStatus] = try await backend.call(
            "prepare_transcription_model",
            arguments: ["model": .string(model)]
        )
        transcriptionModels = next
        return next
    }

    public func removeTranscriptionModel(_ model: String) async throws -> [TranscriptionModelStatus] {
        let next: [TranscriptionModelStatus] = try await backend.call(
            "remove_transcription_model",
            arguments: ["model": .string(model)]
        )
        transcriptionModels = next
        return next
    }

    public func saveDeepgramAPIKey(_ apiKey: String) async throws -> CredentialStatus {
        deepgramCredentialBusy = true
        defer { deepgramCredentialBusy = false }
        let status: CredentialStatus = try await backend.call(
            "save_deepgram_api_key",
            arguments: ["apiKey": .string(apiKey)]
        )
        deepgramCredential = status
        return status
    }

    public func removeDeepgramAPIKey() async throws -> CredentialStatus {
        deepgramCredentialBusy = true
        defer { deepgramCredentialBusy = false }
        let status: CredentialStatus = try await backend.call("remove_deepgram_api_key")
        deepgramCredential = status
        return status
    }

    public func saveElevenLabsAPIKey(_ apiKey: String) async throws -> CredentialStatus {
        elevenLabsCredentialBusy = true
        defer { elevenLabsCredentialBusy = false }
        let status: CredentialStatus = try await backend.call(
            "save_elevenlabs_api_key",
            arguments: ["apiKey": .string(apiKey)]
        )
        elevenLabsCredential = status
        return status
    }

    public func removeElevenLabsAPIKey() async throws -> CredentialStatus {
        elevenLabsCredentialBusy = true
        defer { elevenLabsCredentialBusy = false }
        let status: CredentialStatus = try await backend.call("remove_elevenlabs_api_key")
        elevenLabsCredential = status
        return status
    }

    public func saveDoubaoCredentials(
        appId: String,
        accessToken: String
    ) async throws -> DoubaoCredentialStatus {
        doubaoCredentialBusy = true
        defer { doubaoCredentialBusy = false }
        let status: DoubaoCredentialStatus = try await backend.call(
            "save_doubao_credentials",
            arguments: [
                "appId": .string(appId),
                "accessToken": .string(accessToken),
            ]
        )
        doubaoCredential = status
        return status
    }

    public func removeDoubaoCredentials() async throws -> DoubaoCredentialStatus {
        doubaoCredentialBusy = true
        defer { doubaoCredentialBusy = false }
        let status: DoubaoCredentialStatus = try await backend.call("remove_doubao_credentials")
        doubaoCredential = status
        return status
    }

    public func mergeTranscriptionModelStatus(_ status: TranscriptionModelStatus) {
        transcriptionModels.removeAll { $0.id == status.id }
        transcriptionModels.append(status)
    }

    private func refreshMeetings(
        _ query: String,
        preferredActive: PreferredActiveMeeting
    ) async {
        do {
            meetingQuery = query
            let nextMeetings: [MeetingSummary] = try await backend.call(
                "list_meetings",
                arguments: ["query": .string(query)]
            )
            meetings = nextMeetings
            let activeId: String? = switch preferredActive {
            case .current: capture.activeMeetingId
            case let .explicit(id): id
            }
            if let activeId {
                if let nextActive = nextMeetings.first(where: { $0.id == activeId }) {
                    activeMeeting = nextActive
                }
            } else {
                activeMeeting = nil
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            let retainedSelection = selectedReference.flatMap { id in
                nextMeetings.contains { $0.id == id } ? id : nil
            }
            let preferredId: String? = switch preferredActive {
            case .current:
                retainedSelection ?? activeId ?? nextMeetings.first?.id
            case .explicit:
                activeId ?? retainedSelection ?? nextMeetings.first?.id
            }
            if let preferredId, preferredId != selectedReference {
                _ = await selectMeeting(preferredId)
            }
            if preferredId == nil {
                selectedReference = nil
                meetingReference = nil
                selectedMeetingId = nil
                meeting = nil
            }
        } catch {
            self.error = errorMessage(error, fallbackKey: "error.loadMeetings")
        }
    }

    private func refreshMeetingOutput(_ meetingId: String) async {
        do {
            let selected = selectedReference == meetingId
            async let nextMeetings: [MeetingSummary] = backend.call(
                "list_meetings",
                arguments: ["query": .string(meetingQuery)]
            )
            let nextMeeting: MeetingDetail? = if selected {
                try await backend.call(
                    "read_meeting",
                    arguments: ["id": .string(meetingId)]
                )
            } else {
                nil
            }
            let listed = try await nextMeetings
            meetings = listed
            activeMeeting = activeCaptureReference.flatMap { activeId in
                listed.first { $0.id == activeId }
            }
            if let nextMeeting, selectedReference == meetingId {
                meetingReference = nextMeeting
                meeting = nextMeeting
            }
        } catch {
            // Preserve the current rendered output when a background refresh fails.
        }
    }

    @discardableResult
    private func generateMeetingOutputIfNeeded(
        _ targetMeeting: MeetingDetail,
        kind: MeetingOutputKind,
        regenerateTitle: Bool = false
    ) async -> Bool {
        let claim = "\(targetMeeting.summary.id):\(kind.rawValue)"
        if let existing = generationClaims[claim] {
            await existing.task.value
            if generationClaims[claim]?.id == existing.id {
                generationClaims[claim] = nil
            }
            if kind == .title, regenerateTitle {
                return await generateMeetingOutputIfNeeded(
                    targetMeeting,
                    kind: kind,
                    regenerateTitle: true
                )
            }
            return false
        }
        let settings = loadGenerationSettings()
        let rule = kind == .title ? settings.title : settings.summary
        guard rule.enabled else { return false }
        if kind == .title {
            guard !targetMeeting.lines.isEmpty else { return false }
            if !regenerateTitle {
                guard targetMeeting.lines.count >= 6,
                      targetMeeting.summary.title == nil,
                      targetMeeting.summary.titleGenerationStatus == "idle" else { return false }
            }
        } else {
            guard !targetMeeting.lines.isEmpty,
                  targetMeeting.summary.summaryGenerationStatus == "idle" else { return false }
        }
        let route = ProviderRoute.resolve(
            config: loadProviderConfiguration(),
            runtimes: runtimes
        )
        guard route.available, let provider = route.provider else { return false }
        let prompt = rule.promptOverride
            ?? (kind == .title ? arcoDefaultTitlePrompt : arcoDefaultSummaryPrompt)
        let claimId = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: MeetingOutputArtifact = try await backend.call(
                    "generate_meeting_output",
                    arguments: [
                        "meetingId": .string(targetMeeting.summary.id),
                        "provider": .string(provider.rawValue),
                        "kind": .string(kind.rawValue),
                        "prompt": .string(prompt),
                        "regenerate": .bool(kind == .title && regenerateTitle),
                    ]
                )
            } catch {
                // Generation failure is recorded in the artifact, not promoted to a UI error.
            }
            await refreshMeetingOutput(targetMeeting.summary.id)
        }
        generationClaims[claim] = GenerationClaim(id: claimId, task: task)
        await task.value
        if generationClaims[claim]?.id == claimId {
            generationClaims[claim] = nil
        }
        return true
    }

    private func generateStoppedMeetingOutputs(_ targetMeeting: MeetingDetail) async {
        _ = await generateMeetingOutputIfNeeded(
            targetMeeting,
            kind: .title,
            regenerateTitle: true
        )
        _ = await generateMeetingOutputIfNeeded(targetMeeting, kind: .summary)
    }

    private func triggerLiveTitleGenerationIfNeeded() {
        guard capture.phase == .recording,
              let activeId = capture.activeMeetingId,
              let targetMeeting = liveMeetingReference ?? meeting,
              targetMeeting.summary.id == activeId else { return }
        guard let bucket = MeetingTitleRefreshPolicy.bucket(
            startedAt: capture.startedAt,
            now: now()
        ) else { return }
        let previousBucket = liveTitleRefreshBuckets[activeId] ?? 0
        guard bucket > previousBucket else { return }
        liveTitleRefreshBuckets[activeId] = bucket
        Task { @MainActor [weak self] in
            _ = await self?.generateMeetingOutputIfNeeded(
                targetMeeting,
                kind: .title,
                regenerateTitle: true
            )
        }
    }

    private func applyCapture(_ next: CaptureState) {
        let previousPhase = capture.phase
        let previousId = capture.activeMeetingId
        activeCaptureReference = next.activeMeetingId
        guard capture != next else { return }
        capture = next
        if next.phase == .recording,
           let activeId = next.activeMeetingId,
           meetingReference?.summary.id == activeId {
            liveMeetingReference = meetingReference
        }
        if previousPhase == .recording, next.phase != .recording {
            captureSurfaces.releaseCaptureSurfaces()
        }
        if let previousId,
           previousId != next.activeMeetingId
            || (previousPhase == .recording && next.phase != .recording) {
            liveTitleRefreshBuckets[previousId] = nil
            liveMeetingReference = nil
        }
        if previousPhase != next.phase || previousId != next.activeMeetingId {
            updateLivePolling()
        }
        triggerLiveTitleGenerationIfNeeded()
    }

    private func updateLivePolling() {
        pollTask?.cancel()
        pollTask = nil
        guard capture.phase == .recording, let activeMeetingId = capture.activeMeetingId else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(450))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                do {
                    let knownRevision = liveMeetingRevisions[activeMeetingId]
                    let snapshot: LiveMeetingPoll = try await backend.callDecodedOffMain(
                        "poll_live_meeting",
                        arguments: [
                            "meetingId": .string(activeMeetingId),
                            "knownRevision": knownRevision.map(AnySendable.string) ?? .null,
                        ]
                    )
                    applyCapture(snapshot.capture)
                    if let revision = snapshot.revision {
                        liveMeetingRevisions[activeMeetingId] = revision
                    }
                    if let nextMeeting = snapshot.meeting {
                        liveMeetingReference = nextMeeting
                        if activeMeeting != nextMeeting.summary {
                            activeMeeting = nextMeeting.summary
                        }
                        if selectedReference == activeMeetingId,
                           meetingReference != nextMeeting {
                            meetingReference = nextMeeting
                            meeting = nextMeeting
                        }
                    } else if snapshot.capture.activeMeetingId == nil {
                        activeMeeting = nil
                    }
                    triggerLiveTitleGenerationIfNeeded()
                    if snapshot.capture.phase != .recording
                        || snapshot.capture.activeMeetingId != activeMeetingId {
                        liveMeetingRevisions[activeMeetingId] = nil
                        return
                    }
                } catch {
                    self.error = errorMessage(error, fallbackKey: "error.liveDisconnected")
                }
            }
        }
    }

    private func synchronizeCaptureSurfaces(with state: CaptureState) {
        if state.phase == .recording {
            do { try captureSurfaces.showCaptureHUD() } catch {
                self.error = error.localizedDescription
            }
        } else {
            captureSurfaces.releaseCaptureSurfaces()
        }
    }

    private func handle(_ event: BackendEvent) async {
        guard !disposed else { return }
        switch event.name {
        case "arco:capture-changed":
            _ = await syncCapture()
        case "arco:agent-thread-changed":
            if let id = try? event.decode(String.self) {
                _ = await refreshAgentTurns(id)
                _ = await refreshSavedNotes(noteQuery)
            }
        case "arco:agent-attachments-changed":
            if let id = try? event.decode(String.self) { _ = await refreshAttachments(id) }
        case "arco:agent-target-changed":
            if let id = try? event.decode(String.self) { _ = await selectMeeting(id) }
        case "arco:meeting-output-changed":
            if let id = try? event.decode(String.self) { await refreshMeetingOutput(id) }
        case "arco:notes-changed":
            _ = await refreshSavedNotes(noteQuery)
        case "arco:agent-stream":
            guard let stream = try? event.decode(AgentStreamEvent.self),
                  agentStreamingTurn?.requestId == stream.requestId,
                  agentStreamingTurn?.meetingId == stream.meetingId else { return }
            if stream.type == "status", let phase = stream.phase {
                agentStreamingTurn?.phase = phase
            } else if stream.type == "answer", let answer = stream.answer {
                agentStreamingTurn?.answer = answer
            } else if stream.type == "tool", var tool = stream.tool {
                agentStreamingTurn?.phase = "using-tools"
                if let index = agentStreamingTurn?.toolActivities.firstIndex(where: { $0.id == tool.id }) {
                    let previous = agentStreamingTurn?.toolActivities[index]
                    tool.detail = tool.detail ?? previous?.detail
                    tool.output = tool.output ?? previous?.output
                    agentStreamingTurn?.toolActivities[index] = tool
                } else {
                    agentStreamingTurn?.toolActivities.append(tool)
                }
            }
        case "arco:transcription-model-progress":
            if let status = try? event.decode(TranscriptionModelStatus.self) {
                mergeTranscriptionModelStatus(status)
            }
        default:
            break
        }
    }

    private func errorMessage(_ error: Error, fallbackKey: String) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? translate(fallbackKey, [:]) : message
    }
}
