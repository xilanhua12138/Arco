@_spi(Testing) import ArcoNativeUI
import AppKit
import AVFoundation
import SwiftUI

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
        playback.seek(1); assert(playback.activeLine(in: [line]) == "one")
        playback.seek(5); assert(playback.activeLine(in: [line]) == nil)
        playback.clear(); assert(playback.duration == 0 && !playback.isPlaying)
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
    static func tone(_ url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.02 * sin(Float(i) * 2 * .pi * 220 / 16000) }
        try file.write(from: buffer)
    }
}
