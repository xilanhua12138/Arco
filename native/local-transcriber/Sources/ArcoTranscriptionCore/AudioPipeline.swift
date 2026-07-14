import Foundation

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

/// Energy endpointing is deliberately independent from ASR and diarization.
/// It bounds Whisper work and gives both providers the same finalization rules.
public struct StreamingEndpointDetector: Sendable {
    public var threshold: Float
    public var minimumSpeechSamples: Int
    public var trailingSilenceSamples: Int
    public var preRollSamples: Int

    private var absoluteSample = 0
    private var speechStart: Int?
    private var lastVoicedSample: Int?
    private var bufferStart = 0
    private var buffer: [Float] = []

    public init(
        threshold: Float = 0.008,
        minimumSpeechSamples: Int = 8_000,
        trailingSilenceSamples: Int = 9_600,
        preRollSamples: Int = 3_200
    ) {
        self.threshold = threshold
        self.minimumSpeechSamples = minimumSpeechSamples
        self.trailingSilenceSamples = trailingSilenceSamples
        self.preRollSamples = preRollSamples
    }

    public mutating func push(_ samples: [Float]) -> [SpeechUtterance] {
        guard !samples.isEmpty else { return [] }
        var emitted: [SpeechUtterance] = []
        for sample in samples {
            buffer.append(sample)
            let voiced = abs(sample) >= threshold
            if voiced {
                if speechStart == nil {
                    speechStart = max(bufferStart, absoluteSample - preRollSamples)
                }
                lastVoicedSample = absoluteSample
            }
            absoluteSample += 1

            if let start = speechStart, let last = lastVoicedSample,
               absoluteSample - last >= trailingSilenceSamples
            {
                let end = min(absoluteSample, last + trailingSilenceSamples)
                if end - start >= minimumSpeechSamples {
                    let lower = max(0, start - bufferStart)
                    let upper = min(buffer.count, end - bufferStart)
                    emitted.append(SpeechUtterance(
                        samples: Array(buffer[lower..<upper]),
                        startSample: start,
                        endSample: end
                    ))
                }
                discard(before: end)
                speechStart = nil
                lastVoicedSample = nil
            } else if speechStart == nil && buffer.count > preRollSamples {
                discard(before: absoluteSample - preRollSamples)
            }
        }
        return emitted
    }

    public mutating func finish() -> SpeechUtterance? {
        guard let start = speechStart else { return nil }
        let end = absoluteSample
        let lower = max(0, start - bufferStart)
        guard end - start >= minimumSpeechSamples, lower < buffer.count else { return nil }
        return SpeechUtterance(
            samples: Array(buffer[lower...]),
            startSample: start,
            endSample: end
        )
    }

    private mutating func discard(before sample: Int) {
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
