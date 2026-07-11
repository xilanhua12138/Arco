import FluidAudio
import Foundation
import SwiftWhisper

public struct TimedText: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
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
        return [TimedText(text: text, start: start, end: end)]
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
    }

    public func transcribe(samples: [Float], language: String) async throws -> [TimedText] {
        guard samples.count >= 16_000 else { return [] }
        switch language {
        case "zh-CN": whisper.params.language = .chinese
        case "en-US": whisper.params.language = .english
        default: whisper.params.language = .auto
        }
        return try await whisper.transcribe(audioFrames: samples).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TimedText(
                text: text,
                start: Double(segment.startTime) / 1_000,
                end: Double(segment.endTime) / 1_000
            )
        }
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

public final class StreamingSpeakerDiarizer: @unchecked Sendable {
    private var diarizers: [SortformerDiarizer]

    public init(cacheDirectory: URL, channelCount: Int = 2) async throws {
        var config = SortformerConfig.fastV2_1
        config.precision = .palettized
        let models = try await SortformerModels.loadFromHuggingFace(
            config: config,
            cacheDirectory: cacheDirectory,
            computeUnits: .cpuAndNeuralEngine
        )
        diarizers = (0..<channelCount).map { _ in
            var timeline = DiarizerTimelineConfig.sortformerDefault
            timeline.storeSegments = false
            let diarizer = SortformerDiarizer(config: config, timelineConfig: timeline)
            diarizer.initialize(models: models)
            return diarizer
        }
    }

    public func process(channel: Int, samples: [Float]) throws -> SpeakerTimelineUpdate? {
        guard diarizers.indices.contains(channel) else { return nil }
        guard let update = try diarizers[channel].process(samples: samples, sourceSampleRate: 16_000) else {
            return nil
        }
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
    private let writer: TranscriptWriter
    private let language: String
    private var detectors = [StreamingEndpointDetector(), StreamingEndpointDetector()]
    private var finalizedSpeakerIntervals = [[SpeakerInterval](), [SpeakerInterval]()]
    private var tentativeSpeakerIntervals = [[SpeakerInterval](), [SpeakerInterval]()]

    public init(
        provider: any LocalTranscriptionProvider,
        diarizer: StreamingSpeakerDiarizer?,
        writer: TranscriptWriter,
        language: String
    ) {
        self.provider = provider
        self.diarizer = diarizer
        self.writer = writer
        self.language = language
    }

    public func consume(_ data: Data) async throws {
        let channels = PCMDecoder.splitStereoInt16LE(data)
        try await consume(channel: 0, samples: channels.system)
        try await consume(channel: 1, samples: channels.microphone)
    }

    public func finish() async throws {
        for channel in detectors.indices {
            if let utterance = detectors[channel].finish() {
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
        for utterance in detectors[channel].push(samples) {
            try await transcribe(utterance, channel: channel)
        }
    }

    private func transcribe(_ utterance: SpeechUtterance, channel: Int) async throws {
        let offset = Double(utterance.startSample) / 16_000
        let utteranceEnd = Double(utterance.endSample) / 16_000
        for segment in try await provider.transcribe(samples: utterance.samples, language: language) {
            let start = offset + segment.start
            let end = min(utteranceEnd, offset + max(segment.start, segment.end))
            let speaker = SpeakerAttribution.dominantSpeaker(
                from: finalizedSpeakerIntervals[channel] + tentativeSpeakerIntervals[channel],
                start: start,
                end: end
            ) ?? 0
            try writer.append(TranscriptSegment(
                channel: channel,
                speaker: speaker,
                text: segment.text,
                start: start,
                end: end
            ))
        }
    }
}
