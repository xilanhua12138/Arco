import Foundation
import FluidAudio

public enum PCMDecoder {
    public static func splitStereoInt16LE(_ data: Data) -> (system: [Float], microphone: [Float]) {
        let frameCount = data.count / 4
        var system = [Float]()
        var microphone = [Float]()
        system.reserveCapacity(frameCount)
        microphone.reserveCapacity(frameCount)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for frame in 0..<frameCount {
                let offset = frame * 4
                let left = Int16(bitPattern: UInt16(base[offset]) | UInt16(base[offset + 1]) << 8)
                let right = Int16(bitPattern: UInt16(base[offset + 2]) | UInt16(base[offset + 3]) << 8)
                system.append(Float(left) / 32_768)
                microphone.append(Float(right) / 32_768)
            }
        }
        return (system, microphone)
    }
}

public struct SpeechUtterance: Sendable, Equatable {
    public let samples: [Float]
    public let startSample: Int
    public let endSample: Int

    public init(samples: [Float], startSample: Int, endSample: Int) {
        self.samples = samples
        self.startSample = startSample
        self.endSample = endSample
    }
}

public enum VoiceActivityEventKind: Sendable, Equatable {
    case speechStart
    case speechEnd
}

public struct VoiceActivityEvent: Sendable, Equatable {
    public let kind: VoiceActivityEventKind
    public let sampleIndex: Int

    public init(kind: VoiceActivityEventKind, sampleIndex: Int) {
        self.kind = kind
        self.sampleIndex = sampleIndex
    }
}

public struct VoiceActivityDecision: Sendable, Equatable {
    public let event: VoiceActivityEvent?
    public let probability: Float

    public init(event: VoiceActivityEvent? = nil, probability: Float = 0) {
        self.event = event
        self.probability = probability
    }
}

/// Stateful per-channel model inference. The production implementation wraps
/// FluidAudio's Core ML Silero VAD; the protocol keeps endpointing deterministic
/// under synthetic event streams in the sidecar contract tests.
public protocol VoiceActivitySession: Sendable {
    func process(_ samples: [Float]) async throws -> VoiceActivityDecision
}

public actor FluidAudioVoiceActivitySession: VoiceActivitySession {
    private let manager: VadManager
    private let segmentation: VadSegmentationConfig
    private var state = VadStreamState.initial()

    public init(manager: VadManager) {
        self.manager = manager
        self.segmentation = VadSegmentationConfig(
            minSpeechDuration: 0.2,
            minSilenceDuration: 0.6,
            maxSpeechDuration: 30,
            speechPadding: 0.2
        )
    }

    public func process(_ samples: [Float]) async throws -> VoiceActivityDecision {
        let result = try await manager.processStreamingChunk(
            samples,
            state: state,
            config: segmentation
        )
        state = result.state
        let event = result.event.map { event in
            let kind: VoiceActivityEventKind
            switch event.kind {
            case .speechStart: kind = .speechStart
            case .speechEnd: kind = .speechEnd
            }
            return VoiceActivityEvent(
                kind: kind,
                sampleIndex: event.sampleIndex
            )
        }
        return VoiceActivityDecision(event: event, probability: result.probability)
    }
}

/// Model-backed endpointing is deliberately independent from ASR and
/// diarization. Each source channel owns a separate Silero stream state, while
/// the shared Core ML model stays loaded once for the lifetime of the sidecar.
public actor StreamingEndpointDetector {
    private let session: any VoiceActivitySession
    private let modelChunkSize: Int
    private let minimumSpeechSamples: Int
    private let maximumSpeechSamples: Int
    private let idleRetentionSamples: Int

    private var receivedSamples = 0
    private var processedSamples = 0
    private var speechStart: Int?
    private var bufferStart = 0
    private var buffer: [Float] = []

    public var bufferedSampleCount: Int { buffer.count }

    public init(
        session: any VoiceActivitySession,
        modelChunkSize: Int = VadManager.chunkSize,
        minimumSpeechSamples: Int = 8_000,
        maximumSpeechSamples: Int = 480_000,
        idleRetentionSamples: Int = VadManager.chunkSize + 3_200
    ) {
        precondition(modelChunkSize > 0, "modelChunkSize must be positive")
        precondition(minimumSpeechSamples > 0, "minimumSpeechSamples must be positive")
        precondition(maximumSpeechSamples >= modelChunkSize, "maximumSpeechSamples must fit a model chunk")
        precondition(maximumSpeechSamples >= minimumSpeechSamples, "maximumSpeechSamples must fit minimum speech")
        precondition(idleRetentionSamples >= modelChunkSize, "idleRetentionSamples must retain a model chunk")
        self.session = session
        self.modelChunkSize = modelChunkSize
        self.minimumSpeechSamples = minimumSpeechSamples
        self.maximumSpeechSamples = maximumSpeechSamples
        self.idleRetentionSamples = idleRetentionSamples
    }

    public func push(_ samples: [Float]) async throws -> [SpeechUtterance] {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        receivedSamples += samples.count

        var emitted: [SpeechUtterance] = []
        while receivedSamples - processedSamples >= modelChunkSize {
            let lower = processedSamples - bufferStart
            let upper = lower + modelChunkSize
            guard lower >= 0, upper <= buffer.count else {
                throw RuntimeError("Silero VAD audio buffer lost its model chunk alignment.")
            }
            let decision = try await session.process(Array(buffer[lower..<upper]))
            processedSamples += modelChunkSize
            consume(decision, emitted: &emitted)
        }
        return emitted
    }

    public func finish() async throws -> [SpeechUtterance] {
        var emitted: [SpeechUtterance] = []
        if processedSamples < receivedSamples {
            let lower = processedSamples - bufferStart
            let upper = receivedSamples - bufferStart
            guard lower >= 0, lower < upper, upper <= buffer.count else {
                throw RuntimeError("Silero VAD audio buffer lost its final chunk alignment.")
            }
            let decision = try await session.process(Array(buffer[lower..<upper]))
            processedSamples = receivedSamples
            consume(decision, emitted: &emitted)
        }
        if let start = speechStart {
            appendUtterance(from: start, to: receivedSamples, into: &emitted)
        }
        speechStart = nil
        discard(before: receivedSamples)
        return emitted
    }

    private func consume(_ decision: VoiceActivityDecision, emitted: inout [SpeechUtterance]) {
        if let event = decision.event {
            let sampleIndex = min(processedSamples, max(0, event.sampleIndex))
            switch event.kind {
            case .speechStart:
                if speechStart == nil {
                    speechStart = max(bufferStart, sampleIndex)
                }
            case .speechEnd:
                if let start = speechStart {
                    appendMaximumSegments(from: start, through: sampleIndex, into: &emitted)
                    if let remainingStart = speechStart {
                        appendUtterance(from: remainingStart, to: sampleIndex, into: &emitted)
                    }
                }
                speechStart = nil
                discard(before: sampleIndex)
            }
        }

        if let start = speechStart {
            appendMaximumSegments(from: start, through: processedSamples, into: &emitted)
        } else {
            discard(before: max(0, processedSamples - idleRetentionSamples))
        }
    }

    private func appendMaximumSegments(
        from initialStart: Int,
        through end: Int,
        into emitted: inout [SpeechUtterance]
    ) {
        var start = initialStart
        while end - start >= maximumSpeechSamples {
            let split = start + maximumSpeechSamples
            appendUtterance(from: start, to: split, into: &emitted)
            discard(before: split)
            start = split
        }
        speechStart = start
    }

    private func appendUtterance(from start: Int, to end: Int, into emitted: inout [SpeechUtterance]) {
        let actualStart = max(start, bufferStart)
        let actualEnd = min(end, bufferStart + buffer.count)
        guard actualEnd - actualStart >= minimumSpeechSamples else { return }
        let lower = actualStart - bufferStart
        let upper = actualEnd - bufferStart
        emitted.append(SpeechUtterance(
            samples: Array(buffer[lower..<upper]),
            startSample: actualStart,
            endSample: actualEnd
        ))
    }

    private func discard(before sample: Int) {
        let count = min(buffer.count, max(0, sample - bufferStart))
        if count > 0 {
            buffer.removeFirst(count)
            bufferStart += count
        }
    }
}

public struct SpeakerInterval: Sendable, Equatable, Codable {
    public let speaker: Int
    public let start: Double
    public let end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public enum SpeakerAttribution {
    public static func dominantSpeaker(
        from intervals: [SpeakerInterval],
        start: Double,
        end: Double
    ) -> Int? {
        guard end > start else { return nil }
        var overlap: [Int: Double] = [:]
        for interval in intervals {
            let duration = max(0, min(end, interval.end) - max(start, interval.start))
            if duration > 0 { overlap[interval.speaker, default: 0] += duration }
        }
        return overlap.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key
    }
}

public struct TranscriptSegment: Sendable, Equatable {
    public let channel: Int
    public let speaker: Int
    public let text: String
    public let start: Double
    public let end: Double

    public init(channel: Int, speaker: Int, text: String, start: Double, end: Double) {
        self.channel = channel
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }
}

public final class TranscriptWriter: @unchecked Sendable {
    private let path: URL
    private let sessionStartedAt: Date
    private let lock = NSLock()

    public init(path: URL, sessionStartedAt: Date) {
        self.path = path
        self.sessionStartedAt = sessionStartedAt
    }

    public func append(_ segment: TranscriptSegment) throws {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let prefix = segment.channel == 0 ? "Remote" : "In room"
        let timestamp = Self.clock.string(from: sessionStartedAt.addingTimeInterval(segment.start))
        let block = "**[\(timestamp)] \(prefix) \(segment.speaker + 1):** \(text)\n\n"
            + "<!-- arco channel=\(segment.channel) speaker=\(segment.speaker) stream=local "
            + String(format: "start=%.3f end=%.3f", segment.start, segment.end) + " -->\n\n"
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(block.utf8))
        try handle.synchronize()
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
