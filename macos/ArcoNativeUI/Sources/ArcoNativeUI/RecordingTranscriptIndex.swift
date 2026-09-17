import SwiftUI

/// Search by time while preserving transcript order when speakers overlap.
@_spi(Testing)
public struct RecordingTranscriptIndex {
    private struct Entry {
        let id: String
        let order: Int
        let start: Int64
        let end: Int64
        var maximumEnd: Int64
    }
    private let entries: [Entry]

    public init(lines: [TranscriptLine]) {
        var entries = lines.enumerated().compactMap { order, line -> Entry? in
            guard let time = line.timing, time.endMs > time.startMs else { return nil }
            return Entry(id: line.id, order: order, start: time.startMs, end: time.endMs, maximumEnd: time.endMs)
        }.sorted { $0.start < $1.start }
        var maximum = Int64.min
        for i in entries.indices {
            maximum = max(maximum, entries[i].end)
            entries[i].maximumEnd = maximum
        }
        self.entries = entries
    }

    public func lineID(at ms: Int64) -> String? {
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].start <= ms { low = middle + 1 } else { high = middle }
        }
        var i = low - 1
        var match: Entry?
        while i >= 0 && entries[i].maximumEnd > ms {
            let entry = entries[i]
            if entry.end > ms && entry.order < (match?.order ?? Int.max) { match = entry }
            i -= 1
        }
        return match?.id
    }
}

/// Keep link construction out of playback ticks and hover/scroll redraws.
@_spi(Testing)
@MainActor
public final class RecordingTranscriptTextCache {
    private var line: TranscriptLine?
    private var seekable = false
    private var base = AttributedString()
    private var words: [(range: Range<AttributedString.Index>, start: Int64, end: Int64)] = []
    private var activeWords: [Int] = []
    private var rendered = AttributedString()
    public private(set) var wordRanges: [NSRange] = []
    public private(set) var linkBuildCount = 0
    public private(set) var highlightBuildCount = 0

    public init() {}

    public func text(for line: TranscriptLine, seekable: Bool, positionMs: Int64?) -> AttributedString {
        if self.line != line || self.seekable != seekable {
            self.line = line; self.seekable = seekable
            base = AttributedString(line.text); words = []; wordRanges = []; activeWords = []
            if seekable, let timing = line.timing {
                base.link = URL(string: "arco-audio://seek/\(timing.startMs)")
                var cursor = line.text.startIndex
                for word in timing.words {
                    let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty,
                          let range = line.text.range(of: token, options: [.caseInsensitive], range: cursor..<line.text.endIndex),
                          let lower = AttributedString.Index(range.lowerBound, within: base),
                          let upper = AttributedString.Index(range.upperBound, within: base) else { continue }
                    base[lower..<upper].link = URL(string: "arco-audio://seek/\(word.startMs)")
                    words.append((lower..<upper, word.startMs, word.endMs))
                    wordRanges.append(NSRange(range, in: line.text))
                    cursor = range.upperBound
                }
            }
            rendered = base
            linkBuildCount += 1
        }
        let active = positionMs.map { ms in words.indices.filter { words[$0].start <= ms && ms < words[$0].end } } ?? []
        if active != activeWords {
            rendered = base
            for i in active { rendered[words[i].range].backgroundColor = ArcoNativeColors.action.opacity(0.22) }
            activeWords = active
            highlightBuildCount += 1
        }
        return rendered
    }
}
