import CoreML
import FluidAudio
import Foundation
import SwiftWhisper

public struct TimedText: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public let words: [TranscriptWord]

    public init(text: String, start: Double, end: Double, words: [TranscriptWord] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

/// whisper.cpp's max_len word splitting strips boundary spaces. Restore
/// readable prose without adding spaces between Chinese characters.
public func joinedWhisperWords(_ words: [TranscriptWord]) -> String {
    func cjk(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x9fff).contains(scalar.value) || (0x20000...0x3134f).contains(scalar.value)
                || (0x3040...0x30ff).contains(scalar.value) || (0xac00...0xd7af).contains(scalar.value)
        }
    }
    var text = ""
    for word in words {
        let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = token.first else { continue }
        if let last = text.last, !cjk(last), !cjk(first),
           !",.;:!?%)]}，。！？、；：）】'’".contains(first), !"([{（【'’".contains(last) { text += " " }
        text += token
    }
    return text
}

public protocol LocalTranscriptionProvider: Sendable {
    func transcribe(samples: [Float], language: String) async throws -> [TimedText]
}

public actor NemotronTranscriptionProvider: LocalTranscriptionProvider {
    private let manager: StreamingNemotronMultilingualAsrManager

    public init(modelDirectory: URL) async throws {
        manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: modelDirectory)
    }

    public func transcribe(samples: [Float], language: String) async throws -> [TimedText] {
        await manager.reset()
        await manager.setLanguage(language)
        _ = try await manager.process(samples: samples)
        let result = try await manager.finishWithTokenTimings()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let start = result.timings.first?.startTime ?? 0
        let end = result.timings.last?.endTime ?? Double(samples.count) / 16_000
        let words = result.timings.compactMap { timing -> TranscriptWord? in
            let token = timing.token.replacingOccurrences(of: "▁", with: " ")
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptWord(text: token, startMs: Int64((timing.startTime * 1000).rounded()), endMs: Int64((timing.endTime * 1000).rounded()))
        }
        return [TimedText(text: text, start: start, end: end, words: words)]
    }
}

public actor WhisperTranscriptionProvider: LocalTranscriptionProvider {
    // SwiftWhisper owns an internal C context and dispatches completion back to
    // the main queue. This provider actor serializes every access to that context.
    nonisolated(unsafe) private let whisper: Whisper

    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RuntimeError("Whisper model is not installed: \(modelURL.lastPathComponent)")
        }
        whisper = Whisper(fromFileURL: modelURL)
        whisper.params.token_timestamps = true
        whisper.params.max_len = 1
        whisper.params.split_on_word = true
    }

    public func transcribe(samples: [Float], language: String) async throws -> [TimedText] {
        guard samples.count >= 16_000 else { return [] }
        switch language {
        case "zh-CN": whisper.params.language = .chinese
        case "en-US": whisper.params.language = .english
        default: whisper.params.language = .auto
        }
        let segments = try await whisper.transcribe(audioFrames: samples)
        let words = segments.compactMap { segment -> TranscriptWord? in
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptWord(text: segment.text, startMs: Int64(segment.startTime), endMs: Int64(segment.endTime))
        }
        guard let first = words.first, let last = words.last else { return [] }
        return [TimedText(text: joinedWhisperWords(words),
                          start: Double(first.startMs) / 1000, end: Double(last.endMs) / 1000, words: words)]
    }
}

public struct SpeakerTimelineUpdate: Sendable, Equatable {
    public let finalized: [SpeakerInterval]
    public let tentative: [SpeakerInterval]

    public init(finalized: [SpeakerInterval], tentative: [SpeakerInterval]) {
        self.finalized = finalized
        self.tentative = tentative
    }
}

public enum StreamingDiarizationBackend: String, Sendable {
    case sortformer = "sortformer-streaming"
    case pyannoteWeSpeaker = "pyannote-wespeaker-streaming"
    case lseendAmi = "lseend-ami-streaming"
    case lseendDihard3 = "lseend-dihard3-streaming"
}

public final class SlidingWindowSpeakerDiarizer {
    public typealias Inference = (_ samples: [Float], _ startTime: Double) throws -> [SpeakerInterval]

    private let chunkSamples: Int
    private let stepSamples: Int
    private let sampleRate: Int
    private let inference: Inference
    private var buffer: [Float] = []
    private var bufferStartSample = 0
    private var totalSamples = 0
    private var nextWindowStart = 0
    private var finished = false

    public init(
        chunkSamples: Int = 5 * 16_000,
        stepSamples: Int = 2 * 16_000,
        sampleRate: Int = 16_000,
        inference: @escaping Inference
    ) {
        precondition(chunkSamples > 0)
        precondition(stepSamples > 0 && stepSamples <= chunkSamples)
        precondition(sampleRate > 0)
        self.chunkSamples = chunkSamples
        self.stepSamples = stepSamples
        self.sampleRate = sampleRate
        self.inference = inference
    }

    public func process(_ samples: [Float]) throws -> SpeakerTimelineUpdate? {
        guard !finished, !samples.isEmpty else { return nil }
        buffer.append(contentsOf: samples)
        totalSamples += samples.count

        var emitted = false
        var finalized: [SpeakerInterval] = []
        var tentative: [SpeakerInterval] = []
        while totalSamples >= nextWindowStart + chunkSamples {
            emitted = true
            let localStart = nextWindowStart - bufferStartSample
            guard localStart >= 0, localStart + chunkSamples <= buffer.count else {
                throw RuntimeError("Pyannote streaming window fell outside its rolling audio buffer.")
            }
            let window = Array(buffer[localStart..<(localStart + chunkSamples)])
            let windowStart = Double(nextWindowStart) / Double(sampleRate)
            let windowEnd = Double(nextWindowStart + chunkSamples) / Double(sampleRate)
            let boundary = Double(nextWindowStart + stepSamples) / Double(sampleRate)
            let update = Self.split(
                try inference(window, windowStart),
                windowStart: windowStart,
                windowEnd: windowEnd,
                finalizationBoundary: boundary,
                actualEnd: windowEnd
            )
            finalized.append(contentsOf: update.finalized)
            tentative = update.tentative
            nextWindowStart += stepSamples
        }

        guard emitted else { return nil }
        trimBeforeNextWindow()
        return SpeakerTimelineUpdate(finalized: finalized, tentative: tentative)
    }

    public func finalize() throws -> SpeakerTimelineUpdate? {
        guard !finished else { return nil }
        finished = true
        guard totalSamples > nextWindowStart else { return nil }

        let localStart = nextWindowStart - bufferStartSample
        guard localStart >= 0, localStart <= buffer.count else {
            throw RuntimeError("Pyannote final window fell outside its rolling audio buffer.")
        }
        var window = Array(buffer[localStart...])
        if window.count > chunkSamples {
            window = Array(window.prefix(chunkSamples))
        } else if window.count < chunkSamples {
            window.append(contentsOf: repeatElement(0, count: chunkSamples - window.count))
        }

        let windowStart = Double(nextWindowStart) / Double(sampleRate)
        let windowEnd = Double(nextWindowStart + chunkSamples) / Double(sampleRate)
        let actualEnd = Double(totalSamples) / Double(sampleRate)
        let update = Self.split(
            try inference(window, windowStart),
            windowStart: windowStart,
            windowEnd: windowEnd,
            finalizationBoundary: actualEnd,
            actualEnd: actualEnd
        )
        return SpeakerTimelineUpdate(finalized: update.finalized, tentative: [])
    }

    private func trimBeforeNextWindow() {
        let dropCount = min(buffer.count, max(0, nextWindowStart - bufferStartSample))
        guard dropCount > 0 else { return }
        buffer.removeFirst(dropCount)
        bufferStartSample += dropCount
    }

    private static func split(
        _ intervals: [SpeakerInterval],
        windowStart: Double,
        windowEnd: Double,
        finalizationBoundary: Double,
        actualEnd: Double
    ) -> SpeakerTimelineUpdate {
        var finalized: [SpeakerInterval] = []
        var tentative: [SpeakerInterval] = []
        let clippedEnd = min(windowEnd, actualEnd)

        for interval in intervals {
            let start = max(windowStart, interval.start)
            let end = min(clippedEnd, interval.end)
            guard start.isFinite, end.isFinite, end > start else { continue }
            let finalizedEnd = min(end, finalizationBoundary)
            if finalizedEnd > start {
                finalized.append(SpeakerInterval(
                    speaker: interval.speaker,
                    start: start,
                    end: finalizedEnd
                ))
            }
            let tentativeStart = max(start, finalizationBoundary)
            if end > tentativeStart {
                tentative.append(SpeakerInterval(
                    speaker: interval.speaker,
                    start: tentativeStart,
                    end: end
                ))
            }
        }
        return SpeakerTimelineUpdate(finalized: finalized, tentative: tentative)
    }
}

public final class StreamingSpeakerDiarizer: @unchecked Sendable {
    private enum Runtime {
        case frame([any Diarizer])
        case sliding([SlidingWindowSpeakerDiarizer])
    }

    private var runtime: Runtime

    public init(
        cacheDirectory: URL,
        backend: StreamingDiarizationBackend = .sortformer,
        channelCount: Int = 2
    ) async throws {
        switch backend {
        case .sortformer:
            var config = SortformerConfig.fastV2_1
            config.precision = .palettized
            let models = try await SortformerModels.loadFromHuggingFace(
                config: config,
                cacheDirectory: cacheDirectory,
                computeUnits: .cpuAndNeuralEngine
            )
            runtime = .frame((0..<channelCount).map { _ in
                var timeline = DiarizerTimelineConfig.sortformerDefault
                timeline.storeSegments = false
                let diarizer = SortformerDiarizer(config: config, timelineConfig: timeline)
                diarizer.initialize(models: models)
                return diarizer as any Diarizer
            })
        case .pyannoteWeSpeaker:
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await DiarizerModels.load(
                from: cacheDirectory,
                configuration: configuration
            )
            runtime = .sliding((0..<channelCount).map { _ in
                var config = DiarizerConfig.default
                config.chunkDuration = 5
                config.chunkOverlap = 0
                let manager = DiarizerManager(config: config)
                manager.initialize(models: models)
                return SlidingWindowSpeakerDiarizer { samples, startTime in
                    try manager.performCompleteDiarization(
                        samples,
                        sampleRate: 16_000,
                        atTime: startTime
                    ).segments.compactMap { segment in
                        guard let oneBasedSpeaker = Int(segment.speakerId), oneBasedSpeaker > 0 else {
                            return nil
                        }
                        return SpeakerInterval(
                            speaker: oneBasedSpeaker - 1,
                            start: Double(segment.startTimeSeconds),
                            end: Double(segment.endTimeSeconds)
                        )
                    }
                }
            })
        case .lseendAmi, .lseendDihard3:
            let variant: LSEENDVariant = backend == .lseendAmi ? .ami : .dihard3
            let model = try await LSEENDModel.loadFromHuggingFace(
                variant: variant,
                stepSize: .step100ms,
                cacheDirectory: cacheDirectory,
                computeUnits: .cpuOnly
            )
            runtime = .frame(try (0..<channelCount).map { _ in
                try LSEENDDiarizer(model: model) as any Diarizer
            })
        }
    }

    public func process(channel: Int, samples: [Float]) throws -> SpeakerTimelineUpdate? {
        switch runtime {
        case .frame(let diarizers):
            guard diarizers.indices.contains(channel) else { return nil }
            guard let update = try diarizers[channel].process(samples: samples, sourceSampleRate: 16_000) else {
                return nil
            }
            return Self.convert(update)
        case .sliding(let diarizers):
            guard diarizers.indices.contains(channel) else { return nil }
            return try diarizers[channel].process(samples)
        }
    }

    public func finalize(channel: Int) throws -> SpeakerTimelineUpdate? {
        switch runtime {
        case .frame(let diarizers):
            guard diarizers.indices.contains(channel), let update = try diarizers[channel].finalizeSession() else {
                return nil
            }
            return Self.convert(update)
        case .sliding(let diarizers):
            guard diarizers.indices.contains(channel) else { return nil }
            return try diarizers[channel].finalize()
        }
    }

    private static func convert(_ update: DiarizerTimelineUpdate) -> SpeakerTimelineUpdate {
        let convert: (DiarizerSegment) -> SpeakerInterval = { segment in
            SpeakerInterval(
                speaker: segment.speakerIndex,
                start: Double(segment.startTime),
                end: Double(segment.endTime)
            )
        }
        return SpeakerTimelineUpdate(
            finalized: update.finalizedSegments.map(convert),
            tentative: update.tentativeSegments.map(convert)
        )
    }
}

public actor LocalStreamRunner {
    private let provider: any LocalTranscriptionProvider
    private let diarizer: StreamingSpeakerDiarizer?
    private let timelineReader: SpeakerTimelineReader?
    private let writer: TranscriptWriter
    private let language: String
    private let detectors: [StreamingEndpointDetector]
    private var finalizedSpeakerIntervals = [[SpeakerInterval](), [SpeakerInterval]()]
    private var tentativeSpeakerIntervals = [[SpeakerInterval](), [SpeakerInterval]()]

    public init(
        provider: any LocalTranscriptionProvider,
        diarizer: StreamingSpeakerDiarizer?,
        timelineReader: SpeakerTimelineReader? = nil,
        writer: TranscriptWriter,
        language: String,
        voiceActivitySessions: [any VoiceActivitySession]
    ) throws {
        guard voiceActivitySessions.count == 2 else {
            throw RuntimeError("Local transcription requires one Silero VAD session per source channel.")
        }
        self.provider = provider
        self.diarizer = diarizer
        self.timelineReader = timelineReader
        self.writer = writer
        self.language = language
        self.detectors = voiceActivitySessions.map { StreamingEndpointDetector(session: $0) }
    }

    public func consume(_ data: Data) async throws {
        let channels = PCMDecoder.splitStereoInt16LE(data)
        try await consume(channel: 0, samples: channels.system)
        try await consume(channel: 1, samples: channels.microphone)
    }

    public func finish() async throws {
        for channel in detectors.indices {
            if let diarizer, let update = try diarizer.finalize(channel: channel) {
                finalizedSpeakerIntervals[channel].append(contentsOf: update.finalized)
                tentativeSpeakerIntervals[channel] = update.tentative
            }
            for utterance in try await detectors[channel].finish() {
                try await transcribe(utterance, channel: channel)
            }
        }
    }

    private func consume(channel: Int, samples: [Float]) async throws {
        if let diarizer, let update = try diarizer.process(channel: channel, samples: samples) {
            finalizedSpeakerIntervals[channel].append(contentsOf: update.finalized)
            // Sortformer revises the open edge on every chunk. Keeping only the
            // latest tentative timeline avoids double-counting stale hypotheses.
            tentativeSpeakerIntervals[channel] = update.tentative
        }
        for utterance in try await detectors[channel].push(samples) {
            try await transcribe(utterance, channel: channel)
        }
    }

    private func transcribe(_ utterance: SpeechUtterance, channel: Int) async throws {
        let offset = Double(utterance.startSample) / 16_000
        let utteranceEnd = Double(utterance.endSample) / 16_000
        for segment in try await provider.transcribe(samples: utterance.samples, language: language) {
            let start = offset + segment.start
            let end = min(utteranceEnd, offset + max(segment.start, segment.end))
            let speaker: Int
            if let timelineReader {
                speaker = await timelineReader.speaker(
                    channel: channel,
                    start: start,
                    end: end
                ) ?? 0
            } else {
                speaker = SpeakerAttribution.dominantSpeaker(
                    from: finalizedSpeakerIntervals[channel] + tentativeSpeakerIntervals[channel],
                    start: start,
                    end: end
                ) ?? 0
            }
            try writer.append(TranscriptSegment(
                channel: channel,
                speaker: speaker,
                text: segment.text,
                start: start,
                end: end,
                words: segment.words.map { word in
                    TranscriptWord(text: word.text, startMs: word.startMs + Int64((offset * 1000).rounded()),
                                   endMs: min(Int64((utteranceEnd * 1000).rounded()), word.endMs + Int64((offset * 1000).rounded())))
                }
            ))
        }
    }
}

public actor DiarizationStreamRunner {
    private let diarizer: StreamingSpeakerDiarizer
    private let writer: SpeakerTimelineWriter
    private var processedSamples = [0, 0]

    public init(diarizer: StreamingSpeakerDiarizer, writer: SpeakerTimelineWriter) {
        self.diarizer = diarizer
        self.writer = writer
    }

    public func consume(_ data: Data) throws {
        let channels = PCMDecoder.splitStereoInt16LE(data)
        try consume(channel: 0, samples: channels.system)
        try consume(channel: 1, samples: channels.microphone)
    }

    public func finish() throws {
        for channel in processedSamples.indices {
            if let update = try diarizer.finalize(channel: channel) {
                try writer.update(
                    channel: channel,
                    processedUntil: Double(processedSamples[channel]) / 16_000,
                    finalized: update.finalized,
                    tentative: update.tentative
                )
            }
        }
    }

    private func consume(channel: Int, samples: [Float]) throws {
        processedSamples[channel] += samples.count
        guard let update = try diarizer.process(channel: channel, samples: samples) else { return }
        try writer.update(
            channel: channel,
            processedUntil: Double(processedSamples[channel]) / 16_000,
            finalized: update.finalized,
            tentative: update.tentative
        )
    }
}
