import ArcoTranscriptionCore
import Foundation

@main
struct ArcoTranscriptionSelfTest {
    static func main() async throws {
        try testStereoSplit()
        try await testModelEndpointEmitsExactBoundaries()
        try await testModelEndpointRejectsNoiseAndShortSpeech()
        try await testModelEndpointSplitsMaximumAndFlushesTail()
        try await testModelEndpointPropagatesInferenceFailure()
        try await testVadDependencyStatus()
        try testAttribution()
        try testTranscriptWriter()
        try testSlidingWindowDiarizer()
        try testModelCatalog()
        try await testPyannoteInstallationStatus()
        try await testStreamingTimelineExchange()
        print("12 local transcription contract tests passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RuntimeError("Self-test failed: \(message)") }
    }

    private static func testStereoSplit() throws {
        let bytes: [UInt8] = [0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x00, 0x00]
        let split = PCMDecoder.splitStereoInt16LE(Data(bytes))
        try require(split.system.count == 2, "stereo frame count")
        try require(abs(split.system[0] - 0.5) < 0.0001, "system sample decoding")
        try require(abs(split.microphone[0] + 0.5) < 0.0001, "microphone sample decoding")
        try require(split.system[1] > 0.99 && split.microphone[1] == 0, "channel isolation")
    }

    private static func testModelEndpointEmitsExactBoundaries() async throws {
        let session = ScriptedVoiceActivitySession([
            VoiceActivityDecision(event: VoiceActivityEvent(kind: .speechStart, sampleIndex: 1)),
            VoiceActivityDecision(),
            VoiceActivityDecision(event: VoiceActivityEvent(kind: .speechEnd, sampleIndex: 10)),
        ])
        let detector = StreamingEndpointDetector(
            session: session,
            modelChunkSize: 4,
            minimumSpeechSamples: 4,
            maximumSpeechSamples: 40,
            idleRetentionSamples: 4
        )
        let samples = (0..<12).map(Float.init)
        let emitted = try await detector.push(samples)
        try require(
            emitted == [SpeechUtterance(samples: Array(samples[1..<10]), startSample: 1, endSample: 10)],
            "model VAD must preserve exact speech event boundaries"
        )
        let receivedChunkSizes = await session.receivedChunkSizes
        try require(receivedChunkSizes == [4, 4, 4], "model VAD chunk contract")
    }

    private static func testModelEndpointRejectsNoiseAndShortSpeech() async throws {
        let noiseSession = ScriptedVoiceActivitySession([
            VoiceActivityDecision(probability: 0.01),
            VoiceActivityDecision(probability: 0.02),
        ])
        let noiseDetector = StreamingEndpointDetector(
            session: noiseSession,
            modelChunkSize: 4,
            minimumSpeechSamples: 4,
            maximumSpeechSamples: 40,
            idleRetentionSamples: 4
        )
        let noiseUtterances = try await noiseDetector.push(Array(repeating: 0, count: 8))
        try require(noiseUtterances.isEmpty, "model VAD must not invent speech without model events")
        let noiseTail = try await noiseDetector.finish()
        let noiseBufferedSamples = await noiseDetector.bufferedSampleCount
        try require(noiseTail.isEmpty, "noise-only stream must not flush an utterance")
        try require(noiseBufferedSamples <= 8, "idle VAD buffer must stay bounded")

        let shortSession = ScriptedVoiceActivitySession([
            VoiceActivityDecision(event: VoiceActivityEvent(kind: .speechStart, sampleIndex: 2)),
            VoiceActivityDecision(event: VoiceActivityEvent(kind: .speechEnd, sampleIndex: 5)),
        ])
        let shortDetector = StreamingEndpointDetector(
            session: shortSession,
            modelChunkSize: 4,
            minimumSpeechSamples: 4,
            maximumSpeechSamples: 40,
            idleRetentionSamples: 4
        )
        let shortUtterances = try await shortDetector.push((0..<8).map(Float.init))
        try require(shortUtterances.isEmpty, "sub-minimum speech must be discarded")
        let shortTail = try await shortDetector.finish()
        try require(shortTail.isEmpty, "discarded short speech must not reappear on finish")
    }

    private static func testModelEndpointSplitsMaximumAndFlushesTail() async throws {
        let session = ScriptedVoiceActivitySession([
            VoiceActivityDecision(event: VoiceActivityEvent(kind: .speechStart, sampleIndex: 0)),
            VoiceActivityDecision(probability: 0.99),
            VoiceActivityDecision(probability: 0.99),
        ])
        let detector = StreamingEndpointDetector(
            session: session,
            modelChunkSize: 4,
            minimumSpeechSamples: 4,
            maximumSpeechSamples: 8,
            idleRetentionSamples: 4
        )
        let samples = (0..<12).map(Float.init)
        let emitted = try await detector.push(samples)
        let tail = try await detector.finish()
        try require(
            emitted == [SpeechUtterance(samples: Array(samples[0..<8]), startSample: 0, endSample: 8)],
            "continuous speech must split at the maximum duration"
        )
        try require(
            tail == [SpeechUtterance(samples: Array(samples[8..<12]), startSample: 8, endSample: 12)],
            "maximum split and final flush must cover the stream without gaps"
        )
    }

    private static func testModelEndpointPropagatesInferenceFailure() async throws {
        let detector = StreamingEndpointDetector(
            session: FailingVoiceActivitySession(),
            modelChunkSize: 4,
            minimumSpeechSamples: 4,
            maximumSpeechSamples: 40,
            idleRetentionSamples: 4
        )
        do {
            _ = try await detector.push([0.9, 0.9, 0.9, 0.9])
            throw RuntimeError("model VAD inference failure was silently ignored")
        } catch FailingVoiceActivitySession.Failure.inference {
            // Expected: never fall back silently to the old energy detector.
        }
    }

    private static func testVadDependencyStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ModelDirectories(root: root)
        try FileManager.default.createDirectory(at: directories.whisper, withIntermediateDirectories: true)
        let whisper = directories.whisper.appendingPathComponent("ggml-tiny.bin")
        FileManager.default.createFile(atPath: whisper.path, contents: nil)
        let handle = try FileHandle(forWritingTo: whisper)
        try handle.truncate(atOffset: UInt64(LocalModelID.whisperTiny.expectedBytes!))
        try handle.close()
        let manager = LocalModelManager(directories: directories)

        let missingVad = await manager.status(.whisperTiny)
        try require(!missingVad.installed, "local ASR must not be ready without Silero VAD")
        try require(missingVad.phase == "not-installed", "missing VAD status phase")
        try require(missingVad.path == nil, "missing VAD must not expose a ready model path")
        do {
            _ = try await manager.loadVoiceActivityManager()
            throw RuntimeError("missing Silero VAD unexpectedly loaded")
        } catch let error as RuntimeError {
            try require(
                error.message == "Silero VAD is not installed. Download the selected on-device transcription model in Arco Settings.",
                "missing Silero VAD must fail with an actionable error"
            )
        }

        let vadModel = directories.vadModelDirectory
        try FileManager.default.createDirectory(at: vadModel, withIntermediateDirectories: true)
        try Data("compiled-model".utf8).write(to: vadModel.appendingPathComponent("model.espresso.net"))

        let corruptVad = await manager.status(.whisperTiny)
        try require(!corruptVad.installed, "partial Silero VAD bundles must be rejected")

        try Data("coreml-data".utf8).write(to: vadModel.appendingPathComponent("coremldata.bin"))

        let ready = await manager.status(.whisperTiny)
        try require(ready.installed, "local ASR must become ready when its ASR and VAD artifacts exist")
        try require(ready.phase == "ready", "ready VAD dependency status phase")
        try require(ready.path == whisper.path, "ready status must keep the ASR model path")
    }

    private static func testAttribution() throws {
        let intervals = [
            SpeakerInterval(speaker: 0, start: 0, end: 1.1),
            SpeakerInterval(speaker: 1, start: 1.0, end: 3.0),
        ]
        try require(
            SpeakerAttribution.dominantSpeaker(from: intervals, start: 0.5, end: 2.5) == 1,
            "maximum-overlap speaker attribution"
        )
        try require(
            SpeakerAttribution.dominantSpeaker(from: [], start: 0, end: 1) == nil,
            "empty speaker timeline"
        )
    }

    private static func testTranscriptWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("transcript.md")
        try Data("# Meeting\n\n".utf8).write(to: transcript)
        let writer = TranscriptWriter(path: transcript, sessionStartedAt: Date(timeIntervalSince1970: 43_200))
        try writer.append(TranscriptSegment(channel: 1, speaker: 2, text: "  hello  ", start: 2, end: 3.5))
        let output = try String(contentsOf: transcript, encoding: .utf8)
        try require(output.contains("In room 3:** hello"), "location speaker label")
        try require(
            output.contains("channel=1 speaker=2 stream=local start=2.000 end=3.500"),
            "timing metadata"
        )
    }

    private static func testSlidingWindowDiarizer() throws {
        var calls: [(sampleCount: Int, startTime: Double)] = []
        let diarizer = SlidingWindowSpeakerDiarizer(
            chunkSamples: 5,
            stepSamples: 2,
            sampleRate: 1
        ) { samples, startTime in
            calls.append((samples.count, startTime))
            return [SpeakerInterval(speaker: 7, start: startTime, end: startTime + 5)]
        }

        let warmup = try diarizer.process([1, 1, 1, 1])
        try require(warmup == nil, "rolling window warmup")
        guard let first = try diarizer.process([1]) else {
            throw RuntimeError("Self-test failed: first rolling window")
        }
        try require(
            first.finalized == [SpeakerInterval(speaker: 7, start: 0, end: 2)],
            "rolling window finalized prefix"
        )
        try require(
            first.tentative == [SpeakerInterval(speaker: 7, start: 2, end: 5)],
            "rolling window tentative overlap"
        )

        guard let second = try diarizer.process([1, 1]) else {
            throw RuntimeError("Self-test failed: second rolling window")
        }
        try require(
            second.finalized == [SpeakerInterval(speaker: 7, start: 2, end: 4)],
            "rolling window next finalized prefix"
        )
        try require(
            second.tentative == [SpeakerInterval(speaker: 7, start: 4, end: 7)],
            "rolling window replaces tentative edge"
        )
        try require(calls.map(\.sampleCount) == [5, 5], "rolling window fixed input size")
        try require(calls.map(\.startTime) == [0, 2], "rolling window step timing")

        let short = SlidingWindowSpeakerDiarizer(
            chunkSamples: 5,
            stepSamples: 2,
            sampleRate: 1
        ) { samples, startTime in
            try require(samples.count == 5, "final rolling window padding")
            return [
                SpeakerInterval(speaker: 3, start: startTime, end: startTime + 5),
                SpeakerInterval(speaker: 4, start: startTime + 6, end: startTime + 7),
            ]
        }
        let shortWarmup = try short.process([1, 1, 1])
        try require(shortWarmup == nil, "short rolling window warmup")
        guard let final = try short.finalize() else {
            throw RuntimeError("Self-test failed: final rolling window")
        }
        try require(
            final.finalized == [SpeakerInterval(speaker: 3, start: 0, end: 3)],
            "final rolling window clamps padded audio"
        )
        try require(final.tentative.isEmpty, "final rolling window clears tentative edge")
        let secondFinalize = try short.finalize()
        try require(secondFinalize == nil, "rolling window finalizes once")
        let postFinal = try short.process([1])
        try require(postFinal == nil, "rolling window rejects post-final audio")
    }

    private static func testModelCatalog() throws {
        try require(LocalModelID.whisperTiny.expectedBytes == 77_691_713, "Whisper Tiny byte contract")
        try require(LocalModelID.whisperBase.expectedBytes == 147_951_465, "Whisper Base byte contract")
        try require(LocalModelID.whisperSmall.expectedBytes == 487_601_967, "Whisper Small byte contract")
        try require(LocalModelID.whisperMedium.expectedBytes == 1_533_763_059, "Whisper Medium byte contract")
        try require(LocalModelID.whisperLarge.expectedBytes == 3_095_033_483, "Whisper Large byte contract")
        try require(LocalModelID.nemotron.expectedBytes == nil, "Core ML models use manifest validation")
        try require(LocalModelID.sortformer.isDiarizer, "Sortformer diarizer catalog")
        try require(LocalModelID.pyannoteWeSpeaker.isDiarizer, "Pyannote diarizer catalog")
        try require(LocalModelID.lseendAmi.isDiarizer, "LS-EEND meeting diarizer catalog")
        try require(LocalModelID.lseendDihard3.isDiarizer, "LS-EEND general diarizer catalog")
        try require(
            StreamingDiarizationBackend(rawValue: LocalModelID.lseendAmi.rawValue) == .lseendAmi,
            "LS-EEND runtime routing"
        )
        try require(
            StreamingDiarizationBackend(rawValue: LocalModelID.pyannoteWeSpeaker.rawValue) == .pyannoteWeSpeaker,
            "Pyannote runtime routing"
        )
    }

    private static func testPyannoteInstallationStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directories = ModelDirectories(root: root)
        try FileManager.default.createDirectory(
            at: directories.pyannoteWeSpeaker,
            withIntermediateDirectories: true
        )
        let requiredModels = ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"]
        for name in requiredModels {
            try FileManager.default.createDirectory(
                at: directories.pyannoteWeSpeaker.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data(directories.pyannoteWeSpeaker.path.utf8).write(
            to: directories.marker(for: .pyannoteWeSpeaker),
            options: .atomic
        )

        let manager = LocalModelManager(directories: directories)
        let ready = await manager.status(.pyannoteWeSpeaker)
        try require(ready.installed, "complete Pyannote model cache is ready")
        try require(
            ready.path == directories.pyannoteWeSpeaker.path,
            "Pyannote cache directory contract"
        )

        guard let missing = requiredModels.first else {
            throw RuntimeError("Self-test failed: Pyannote required model catalog")
        }
        try FileManager.default.removeItem(
            at: directories.pyannoteWeSpeaker.appendingPathComponent(missing, isDirectory: true)
        )
        let incomplete = await manager.status(.pyannoteWeSpeaker)
        try require(!incomplete.installed, "partial Pyannote cache is rejected")
    }

    private static func testStreamingTimelineExchange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("speaker-timeline.json")
        let writer = SpeakerTimelineWriter(path: path)
        try writer.update(
            channel: 1,
            processedUntil: 2,
            finalized: [SpeakerInterval(speaker: 3, start: 0, end: 1)],
            tentative: [SpeakerInterval(speaker: 4, start: 1, end: 2)]
        )
        try writer.update(
            channel: 1,
            processedUntil: 3,
            finalized: [SpeakerInterval(speaker: 4, start: 1, end: 2.5)],
            tentative: [SpeakerInterval(speaker: 5, start: 2.5, end: 3)]
        )

        let reader = SpeakerTimelineReader(path: path)
        let attributed = await reader.speaker(
            channel: 1,
            start: 1.25,
            end: 2.25,
            maxWait: .milliseconds(20)
        )
        let otherChannel = await reader.speaker(
            channel: 0,
            start: 1.25,
            end: 2.25,
            maxWait: .milliseconds(20)
        )
        try require(
            attributed == 4,
            "streaming timeline temporal attribution"
        )
        try require(
            otherChannel == nil,
            "streaming timeline channel isolation"
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try require(files == ["speaker-timeline.json"], "atomic timeline snapshot cleanup")
    }
}

private actor ScriptedVoiceActivitySession: VoiceActivitySession {
    private var decisions: [VoiceActivityDecision]
    private(set) var receivedChunkSizes: [Int] = []

    init(_ decisions: [VoiceActivityDecision]) {
        self.decisions = decisions
    }

    func process(_ samples: [Float]) async throws -> VoiceActivityDecision {
        receivedChunkSizes.append(samples.count)
        guard !decisions.isEmpty else { return VoiceActivityDecision() }
        return decisions.removeFirst()
    }
}

private actor FailingVoiceActivitySession: VoiceActivitySession {
    enum Failure: Error { case inference }

    func process(_: [Float]) async throws -> VoiceActivityDecision {
        throw Failure.inference
    }
}
