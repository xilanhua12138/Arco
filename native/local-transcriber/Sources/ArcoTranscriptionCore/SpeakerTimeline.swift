import Foundation

public struct SpeakerTimelineChannel: Sendable, Equatable, Codable {
    public var processedUntil: Double
    public var finalized: [SpeakerInterval]
    public var tentative: [SpeakerInterval]

    public init(
        processedUntil: Double = 0,
        finalized: [SpeakerInterval] = [],
        tentative: [SpeakerInterval] = []
    ) {
        self.processedUntil = processedUntil
        self.finalized = finalized
        self.tentative = tentative
    }
}

public struct SpeakerTimelineSnapshot: Sendable, Equatable, Codable {
    public var version: Int
    public var channels: [SpeakerTimelineChannel]

    public init(
        version: Int = 1,
        channels: [SpeakerTimelineChannel] = [SpeakerTimelineChannel(), SpeakerTimelineChannel()]
    ) {
        self.version = version
        self.channels = channels
    }
}

public final class SpeakerTimelineWriter: @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()
    private var snapshot = SpeakerTimelineSnapshot()

    public init(path: URL) {
        self.path = path
    }

    public func update(
        channel: Int,
        processedUntil: Double,
        finalized: [SpeakerInterval],
        tentative: [SpeakerInterval]
    ) throws {
        guard snapshot.channels.indices.contains(channel) else { return }
        lock.lock()
        defer { lock.unlock() }

        if processedUntil.isFinite {
            snapshot.channels[channel].processedUntil = max(
                snapshot.channels[channel].processedUntil,
                max(0, processedUntil)
            )
        }
        let validFinalized = finalized.filter(Self.valid)
        for interval in validFinalized where !snapshot.channels[channel].finalized.contains(interval) {
            snapshot.channels[channel].finalized.append(interval)
        }
        snapshot.channels[channel].finalized = Self.compact(snapshot.channels[channel].finalized)
        snapshot.channels[channel].tentative = Self.compact(tentative.filter(Self.valid))
        try flush()
    }

    private func flush() throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: path, options: .atomic)
    }

    private static func valid(_ interval: SpeakerInterval) -> Bool {
        interval.start.isFinite
            && interval.end.isFinite
            && interval.start >= 0
            && interval.end > interval.start
    }

    private static func compact(_ intervals: [SpeakerInterval]) -> [SpeakerInterval] {
        let sorted = intervals.sorted {
            $0.start == $1.start
                ? ($0.end == $1.end ? $0.speaker < $1.speaker : $0.end < $1.end)
                : $0.start < $1.start
        }
        var result: [SpeakerInterval] = []
        for interval in sorted {
            if let previous = result.last,
               previous.speaker == interval.speaker,
               interval.start <= previous.end + 0.02
            {
                result[result.count - 1] = SpeakerInterval(
                    speaker: previous.speaker,
                    start: previous.start,
                    end: max(previous.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }
}

public struct SpeakerTimelineReader: Sendable {
    private let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func speaker(
        channel: Int,
        start: Double,
        end: Double,
        maxWait: Duration = .milliseconds(1_500)
    ) async -> Int? {
        guard end > start else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxWait)
        while true {
            if let snapshot = read(), snapshot.channels.indices.contains(channel) {
                let timeline = snapshot.channels[channel]
                if timeline.processedUntil + 0.001 >= end || clock.now >= deadline {
                    return SpeakerAttribution.dominantSpeaker(
                        from: timeline.finalized + timeline.tentative,
                        start: start,
                        end: end
                    )
                }
            } else if clock.now >= deadline {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func read() -> SpeakerTimelineSnapshot? {
        guard
            let data = try? Data(contentsOf: path),
            let snapshot = try? JSONDecoder().decode(SpeakerTimelineSnapshot.self, from: data),
            snapshot.version == 1,
            snapshot.channels.count == 2
        else { return nil }
        return snapshot
    }
}
