@_spi(Testing) import ArcoNativeUI
import AppKit
import AVFoundation
import SwiftUI
import Observation

private final class CursorChanges: @unchecked Sendable {
    // Observation callbacks in these tests run synchronously on the main actor.
    var count = 0
}

@main
struct RecordingTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); NSApp.terminate(nil) }
            catch { print("Playback tests failed: \(error)"); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arco-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await verifyCenteredPlayback(folder)
        let file = folder.appendingPathComponent("tone.wav")
        try tone(file, seconds: 3)
        let recording = MeetingRecording(meetingId: "fixture", chunks: [
            RecordingChunk(path: file.path, startMs: 0), RecordingChunk(path: file.path, startMs: 5000)
        ])
        let playback = RecordingPlayback()
        await playback.load(recording)
        assert(abs(playback.duration - 8) < 0.01)
        assert(playback.hasGaps)
        assert(playback.waveform.count == 160 && playback.waveform[0] > 0 && playback.waveform[80] == 0)
        playback.seek(4); assert(playback.position == 5)
        playback.seek(-10); assert(playback.position == 0)
        playback.seek(100); assert(playback.position == 8)
        assert(RecordingPlayback.availablePosition(.nan, ranges: playback.ranges) == nil)
        playback.seek(0.5); playback.muteForTesting(); playback.toggle()
        try await Task.sleep(for: .seconds(1)); playback.tick()
        assert(playback.isPlaying && playback.position > 0.5 && playback.position < 3)
        playback.toggle(); let paused = playback.position
        try await Task.sleep(for: .milliseconds(150)); playback.tick(); assert(playback.position == paused)
        playback.updateRate(1.5); assert(playback.rate == 1.5)
        let line = TranscriptLine(id: "one", timestamp: "12:00:00", speaker: "Remote 1", text: "你好世界。", sequence: 0,
                                  timing: TranscriptTiming(startMs: 0, endMs: 2500, words: [TranscriptWord(text: "你好", startMs: 0, endMs: 1000), TranscriptWord(text: "世界", startMs: 1000, endMs: 2500)]))
        playback.setTranscript([line])
        assert(playback.hasWordTimings)
        playback.seek(0.1)
        let changes = CursorChanges()
        withObservationTracking { _ = playback.activeLineID } onChange: { changes.count += 1 }
        for position in stride(from: 0.2, to: 2.0, by: 0.08) { playback.seek(position) }
        assert(changes.count == 0, "Moving within a sentence must not invalidate the transcript container")
        playback.seek(5)
        assert(changes.count == 1 && playback.activeLineID == nil)
        verifyTranscriptPerformance(line)
        verifyWordHitTesting()
        playback.seek(1); assert(playback.activeLine(in: [line]) == "one")
        playback.seek(5); assert(playback.activeLine(in: [line]) == nil)
        playback.clear(); assert(playback.duration == 0 && !playback.isPlaying && !playback.hasWordTimings)
        let legacy = Data(#"{"id":"a","timestamp":"12:00:00","speaker":"Remote 1","text":"legacy","sequence":0}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptLine.self, from: legacy)
        assert(decoded.timing == nil)
        await playback.load(MeetingRecording(meetingId: "bad", chunks: [RecordingChunk(path: folder.appendingPathComponent("missing.wav").path, startMs: 0)]))
        assert(playback.duration == 0 && !playback.loading)
        print("Recording playback: AVFoundation load/play/pause/seek, missing ranges, rate, highlighting, legacy decoding and lifecycle passed")
        if CommandLine.arguments.contains("--window") || Bundle.main.bundleIdentifier == "app.arco.playback-tests" {
            let summary = MeetingSummary(id: "fixture", title: "录音与转录稿联动验证", generatedSummary: nil, titleGenerationStatus: "idle", summaryGenerationStatus: "idle", startedAt: "2026-09-15T12:00:00+08:00", durationLabel: "1m", preview: "", path: "", utteranceCount: 3, isLive: false, source: "arco")
            let detail = MeetingDetail(summary: summary, lines: [line,
                TranscriptLine(id: "two", timestamp: "12:00:05", speaker: "In room 1", text: "点击这句话，可以从第五秒开始播放。", sequence: 1, timing: TranscriptTiming(startMs: 5000, endMs: 6500)),
                TranscriptLine(id: "three", timestamp: "12:00:06", speaker: "Remote 1", text: "播放时高亮当前位置，也可以拖动进度条和调整播放速度。", sequence: 2, timing: TranscriptTiming(startMs: 6500, endMs: 8000))], rawMarkdown: "")
            let view = TranscriptPaneView(meeting: detail, capture: .idle, loading: false, translate: ArcoTranslations.simplifiedChinese,
                                          onLoadRecording: { _ in recording })
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1080, height: 750), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Arco · Recording playback verification"
            window.contentView = NSHostingView(rootView: view.preferredColorScheme(.light))
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            print("WINDOW_ID=\(window.windowNumber)")
            while window.isVisible { try await Task.sleep(for: .milliseconds(200)) }
        }
    }

    @MainActor static func verifyWordHitTesting() {
        let view = RecordingWordTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 200))
        view.textContainerInset = NSSize(width: 2, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        let text = NSMutableAttributedString(string: "你好世界。\n第二行的文字", attributes: [.font: NSFont.systemFont(ofSize: 14), .link: URL(string: "arco-audio://seek/0")!])
        text.addAttribute(NSAttributedString.Key("ArcoSeekWord"), value: 0, range: NSRange(location: 0, length: 2))
        text.addAttribute(NSAttributedString.Key("ArcoSeekWord"), value: 1, range: NSRange(location: 2, length: 2))
        text.addAttribute(.link, value: URL(string: "arco-audio://seek/1000")!, range: NSRange(location: 2, length: 2))
        view.textStorage!.setAttributedString(text)
        let manager = view.layoutManager!, container = view.textContainer!
        manager.ensureLayout(for: container)
        func center(_ index: Int) -> NSPoint {
            let glyph = manager.glyphIndexForCharacter(at: index)
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        }
        assert(view.hoverTarget(at: center(0)) == NSRange(location: 0, length: 2))
        assert(view.hoverTarget(at: center(1)) == NSRange(location: 0, length: 2))
        assert(view.hoverTarget(at: center(2)) == NSRange(location: 2, length: 2))
        assert(view.hoverTarget(at: NSPoint(x: 170, y: center(2).y)) == nil, "Trailing whitespace must not snap to the nearest word")
        assert(view.hoverTarget(at: NSPoint(x: 100, y: 180)) == nil)
        assert(view.hoverTarget(at: center(7)) == nil, "Sentence-only text must not advertise word precision")
        var clickedWord: URL?
        var sentenceClicks = 0
        view.onSeek = { clickedWord = $0 }
        view.onSeekLine = { sentenceClicks += 1 }
        _ = view.textView(view, clickedOnLink: URL(string: "arco-audio://seek/0")!, at: 2)
        assert(clickedWord == URL(string: "arco-audio://seek/1000"), "Click must resolve the hovered word instead of a coalesced sentence link")
        _ = view.textView(view, clickedOnLink: URL(string: "arco-audio://seek/0")!, at: 7)
        assert(sentenceClicks == 1)
        text.addAttribute(NSAttributedString.Key("ArcoSeekWord"), value: 2, range: NSRange(location: 6, length: 3))
        view.textStorage!.setAttributedString(text)
        assert(view.hoverTarget(at: center(7)) == NSRange(location: 6, length: 3), "Timed words on subsequent lines must remain interactive")
        assert(view.attributedString().attribute(.link, at: 2, effectiveRange: nil) as? URL == URL(string: "arco-audio://seek/1000"))
        print("Native word hit testing: word boundaries, multiline links and trailing whitespace passed")
    }

    @MainActor static func verifyTranscriptPerformance(_ line: TranscriptLine) {
        let cache = RecordingTranscriptTextCache()
        for ms in stride(from: Int64(0), to: 960, by: 80) {
            let text = cache.text(for: line, seekable: true, positionMs: ms)
            assert(text.runs.contains { $0.link?.absoluteString == "arco-audio://seek/0" && $0.backgroundColor != nil })
        }
        assert(cache.linkBuildCount == 1 && cache.highlightBuildCount == 1)
        assert(cache.wordRanges == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
        let next = cache.text(for: line, seekable: true, positionMs: 1500)
        assert(next.runs.contains { $0.link?.absoluteString == "arco-audio://seek/1000" && $0.backgroundColor != nil })
        let native = RecordingWordTextView.renderedText(next, wordRanges: cache.wordRanges)
        assert(native.attribute(.backgroundColor, at: 2, effectiveRange: nil) is NSColor, "Playing-word highlight must bridge to TextKit")
        assert(native.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        let inactive = cache.text(for: line, seekable: true, positionMs: nil)
        assert(inactive.runs.allSatisfy { $0.backgroundColor == nil })
        assert(cache.linkBuildCount == 1 && cache.highlightBuildCount == 3)
        let unavailable = cache.text(for: line, seekable: false, positionMs: 0)
        assert(unavailable.runs.allSatisfy { $0.link == nil })
        var revised = line
        revised.text = "改写后的句子"
        assert(String(cache.text(for: revised, seekable: true, positionMs: nil).characters) == revised.text)

        // Unsorted, overlapping speaker intervals and half-open boundaries
        // must keep the old first-transcript-row selection behavior.
        let lines: [TranscriptLine] = (0..<10_000).map { (i: Int) -> TranscriptLine in
            let start = Int64(i) * 1000
            let timing = TranscriptTiming(startMs: start, endMs: start + 900)
            return TranscriptLine(id: String(i), timestamp: "00:00", speaker: "Remote 1", text: "句子 \(i)", sequence: i, timing: timing)
        }
        var overlapping = Array(lines.prefix(20).reversed())
        overlapping[3].timing = TranscriptTiming(startMs: 0, endMs: 18_000)
        let overlapIndex = RecordingTranscriptIndex(lines: overlapping)
        for ms in stride(from: Int64(-1), through: 21_000, by: 100) {
            let expected = overlapping.first { $0.timing!.startMs <= ms && ms < $0.timing!.endMs }?.id
            assert(overlapIndex.lineID(at: ms) == expected)
        }
        let index = RecordingTranscriptIndex(lines: lines)
        let positions: [Int64] = (0..<2000).map { (i: Int) -> Int64 in
            let ordinal: Int = (i * 7919) % 10_000
            return Int64(ordinal) * 1000 + 500
        }
        let clock = ContinuousClock()
        var expected: [String?] = []
        let linear = clock.measure {
            expected = positions.map { ms in lines.first { $0.timing!.startMs <= ms && ms < $0.timing!.endMs }?.id }
        }
        var actual: [String?] = []
        let indexed = clock.measure { actual = positions.map { index.lineID(at: $0) } }
        assert(actual == expected)
        print("Transcript benchmark: 10,000 lines / 2,000 positions; linear \(linear), indexed \(indexed). Links built once across 12 ticks; container invalidations within a line: 0.")
    }
    static func verifyCenteredPlayback(_ folder: URL) async throws {
        // Actual AVFoundation decoding + playback mix: alternating sources,
        // overlap at full scale, opposite polarity, silence, and legacy mono.
        for channelCount: AVAudioChannelCount in [2, 1] {
            let url = folder.appendingPathComponent("sources-\(channelCount).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: channelCount)!
            let cases: [(Float, Float)] = [(0.8, 0), (0, 0.6), (1, 1), (-1, -1), (0.7, -0.7), (0, 0)]
            let block = 1600
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(cases.count * block))!
            buffer.frameLength = buffer.frameCapacity
            for (segment, samples) in cases.enumerated() {
                for i in segment * block..<(segment + 1) * block {
                    buffer.floatChannelData![0][i] = samples.0
                    if channelCount == 2 { buffer.floatChannelData![1][i] = samples.1 }
                }
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let asset = AVURLAsset(url: url)
            let audio = try await asset.loadTracks(withMediaType: .audio).first!
            let composition = AVMutableComposition()
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: audio, at: .zero)
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: channelCount, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = try RecordingAudioMix.make(for: track)
            reader.add(output)
            assert(reader.startReading())
            var frame = 0
            while let sample = output.copyNextSampleBuffer() {
                let data = CMSampleBufferGetDataBuffer(sample)!
                var bytes = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size)
                let byteCount = bytes.count * MemoryLayout<Float>.size
                let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!) }
                assert(status == noErr)
                for i in stride(from: 0, to: bytes.count, by: Int(channelCount)) {
                    let source = cases[min(cases.count - 1, frame / block)]
                    let expected = channelCount == 2 ? (source.0 + source.1) * 0.5 : source.0
                    assert(abs(bytes[i] - expected) < 0.0001, "Playback mix lost a source or changed mono gain: frame \(frame), actual \(bytes[i]), expected \(expected)")
                    if channelCount == 2 { assert(bytes[i] == bytes[i + 1], "Both ears must receive identical audio") }
                    assert(abs(bytes[i]) <= 1, "Simultaneous sources must not clip")
                    frame += 1
                }
            }
            assert(reader.status == .completed && frame == Int(buffer.frameLength))
        }
        print("Centered playback: AVFoundation stereo source alternation, overlap, silence, full-scale headroom and legacy mono passed")
    }

    static func tone(_ url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.02 * sin(Float(i) * 2 * .pi * 220 / 16000) }
        try file.write(from: buffer)
    }
}
