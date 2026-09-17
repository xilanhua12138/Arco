import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class RecordingPlayback {
    public private(set) var position: Double = 0 {
        didSet { updateTranscriptCursor() }
    }
    public private(set) var activeLineID: String?
    public private(set) var hasWordTimings = false
    @ObservationIgnored private var transcriptIndex = RecordingTranscriptIndex(lines: [])
    public private(set) var duration: Double = 0
    public private(set) var isPlaying = false
    public private(set) var loading = false
    public private(set) var error: String?
    public private(set) var hasGaps = false
    public private(set) var waveform: [Double] = []
    public private(set) var ranges: [ClosedRange<Double>] = []
    public var rate: Float = 1
    public var following = true
    public private(set) var seekRevision = 0
    private var player: AVPlayer?
    private var generation = UUID()
    private var seeking = false
    private var seekID = UUID()

    public init() {}

    public func clear() {
        hasWordTimings = false
        transcriptIndex = RecordingTranscriptIndex(lines: [])
        activeLineID = nil
        generation = UUID()
        seekID = UUID(); seeking = false
        player?.pause(); player = nil
        position = 0; duration = 0; isPlaying = false; loading = false
        error = nil; ranges = []; hasGaps = false; following = true; waveform = []
    }

    public func load(_ recording: MeetingRecording) async {
        clear(); loading = true
        let request = generation
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            loading = false; return
        }
        var available: [ClosedRange<Double>] = []
        var failed = false
        for chunk in recording.chunks.sorted(by: { $0.startMs < $1.startMs }) {
            if Task.isCancelled || request != generation { return }
            do {
                let asset = AVURLAsset(url: URL(fileURLWithPath: chunk.path))
                let length = try await asset.load(.duration).seconds
                guard length.isFinite, length > 0,
                      let audio = try await asset.loadTracks(withMediaType: .audio).first else { failed = true; continue }
                let start = Double(chunk.startMs) / 1000
                // Trim encoder padding at a numbered chunk boundary.
                let next = recording.chunks.map { Double($0.startMs) / 1000 }.filter { $0 > start }.min()
                let usable = min(length, next.map { $0 - start } ?? length)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: usable, preferredTimescale: 16000)),
                                          of: audio, at: CMTime(seconds: start, preferredTimescale: 16000))
                available.append(start...(start + usable))
            } catch { failed = true }
        }
        guard !Task.isCancelled, request == generation else { return }
        loading = false; ranges = available
        guard let first = ranges.first, let last = ranges.last else { return }
        duration = last.upperBound
        hasGaps = failed || first.lowerBound > 0.1 || zip(ranges, ranges.dropFirst()).contains { $1.lowerBound - $0.upperBound > 0.1 }
        let item = AVPlayerItem(asset: composition)
        do { item.audioMix = try RecordingAudioMix.make(for: track) }
        catch { self.error = error.localizedDescription; return }
        player = AVPlayer(playerItem: item)
        seek(first.lowerBound)
        let length = duration
        let waveformTask = Task.detached(priority: .utility) { Self.sampleWaveform(recording.chunks, duration: length) }
        let samples = await withTaskCancellationHandler(operation: { await waveformTask.value }, onCancel: { waveformTask.cancel() })
        if !Task.isCancelled && request == generation { waveform = samples }
    }

    private nonisolated static func sampleWaveform(_ chunks: [RecordingChunk], duration: Double) -> [Double] {
        var files: [String: AVAudioFile] = [:]
        let ordered = chunks.sorted { $0.startMs < $1.startMs }
        return (0..<160).map { index in
            guard !Task.isCancelled else { return 0 }
            let time = (Double(index) + 0.5) / 160 * duration
            guard let chunk = ordered.last(where: { Double($0.startMs) / 1000 <= time }) else { return 0 }
            do {
                let file: AVAudioFile
                if let cached = files[chunk.path] { file = cached }
                else { file = try AVAudioFile(forReading: URL(fileURLWithPath: chunk.path)); files[chunk.path] = file }
                let frame = AVAudioFramePosition((time - Double(chunk.startMs) / 1000) * file.processingFormat.sampleRate)
                guard frame >= 0, frame < file.length else { return 0 }
                file.framePosition = frame
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512) else { return 0 }
                try file.read(into: buffer)
                guard let samples = buffer.floatChannelData else { return 0 }
                var peak: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[channel][i])) }
                }
                return min(1, sqrt(Double(peak)))
            } catch { return 0 }
        }
    }

    public static func availablePosition(_ requested: Double, ranges: [ClosedRange<Double>]) -> Double? {
        guard requested.isFinite else { return nil }
        for range in ranges {
            if requested < range.lowerBound { return range.lowerBound }
            if requested < range.upperBound { return requested }
        }
        return ranges.last?.upperBound
    }

    public func seek(_ seconds: Double) {
        guard let target = Self.availablePosition(seconds, ranges: ranges) else { return }
        position = target; following = true; seekRevision += 1
        let id = UUID(); seekID = id; seeking = true
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 16000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in if self?.seekID == id { self?.seeking = false } }
        }
    }

    public func toggle() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else {
            if position >= duration - 0.05 { seek(ranges.first?.lowerBound ?? 0) }
            player.playImmediately(atRate: rate); isPlaying = true
        }
    }

    public func updateRate(_ value: Float) { rate = value; if isPlaying { player?.rate = value } }

    public func tick() {
        guard let player else { return }
        if player.currentItem?.status == .failed {
            error = player.currentItem?.error?.localizedDescription; player.pause(); isPlaying = false; return
        }
        guard isPlaying, !seeking else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        position = time
        if time >= duration - 0.03 { player.pause(); isPlaying = false; position = duration; return }
        if let next = Self.availablePosition(time, ranges: ranges), next > time + 0.03 { seek(next) }
    }

    public func activeLine(in lines: [TranscriptLine]) -> String? {
        let ms = Int64((position * 1000).rounded())
        return lines.first { line in
            guard let timing = line.timing else { return false }
            return timing.startMs <= ms && ms < timing.endMs
        }?.id
    }

    public func setTranscript(_ lines: [TranscriptLine]) {
        hasWordTimings = lines.contains { !($0.timing?.words.isEmpty ?? true) }
        transcriptIndex = RecordingTranscriptIndex(lines: lines)
        updateTranscriptCursor()
    }

    private func updateTranscriptCursor() {
        let next = transcriptIndex.lineID(at: Int64((position * 1000).rounded()))
        if next != activeLineID { activeLineID = next }
    }

    @_spi(Testing) public func muteForTesting() { player?.isMuted = true }
}

struct RecordingPlayerBar: View {
    @Bindable var playback: RecordingPlayback
    let translate: ArcoTranslate
    @State private var scrubbing = false
    @State private var draft: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if playback.loading {
                Label(translate("playback.loading", [:]), systemImage: "waveform")
                    .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted).frame(height: 40)
            } else if playback.duration > 0 {
                HStack(spacing: 12) {
                    Button { playback.toggle() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .regular)).offset(x: playback.isPlaying ? 0 : 1)
                            .foregroundStyle(Color(white: 0.25)).frame(width: 40, height: 40)
                            .background(Color(white: 0.90), in: Circle())
                    }.buttonStyle(ArcoPressFeedbackButtonStyle(pressedScale: 0.94))
                        .accessibilityLabel(translate(playback.isPlaying ? "playback.pause" : "playback.play", [:]))
                    waveform
                    HStack(spacing: 10) {
                        Text(clock(scrubbing ? draft : playback.position)).foregroundStyle(Color(white: 0.45))
                        Text(clock(playback.duration)).fontWeight(.medium).foregroundStyle(Color(white: 0.25))
                        Button {
                            let rates: [Float] = [1, 1.5, 2]
                            playback.updateRate(rates[((rates.firstIndex(of: playback.rate) ?? 0) + 1) % rates.count])
                        } label: {
                            Text("\(playback.rate.formatted())×").fontWeight(.medium)
                                .foregroundStyle(Color(white: 0.45)).frame(minWidth: 24, minHeight: 28)
                        }.buttonStyle(ArcoPressFeedbackButtonStyle())
                            .accessibilityLabel(translate("playback.speed", [:]))
                            .help(translate("playback.speed", [:]))
                        Button {
                            playback.following.toggle()
                            if playback.following { playback.seek(playback.position) }
                        } label: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 13)).frame(width: 28, height: 28)
                                .foregroundStyle(playback.following ? ArcoNativeColors.action : Color(white: 0.45))
                        }.buttonStyle(ArcoPressFeedbackButtonStyle())
                            .accessibilityLabel(translate(playback.following ? "playback.following" : "playback.follow", [:]))
                            .help(translate(playback.following ? "playback.following" : "playback.follow", [:]))
                    }.font(ArcoTypography.sans(12)).monospacedDigit().fixedSize()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 16))
                if playback.hasGaps {
                    Text(translate("playback.partial", [:])).font(ArcoTypography.sans(11)).foregroundStyle(ArcoNativeColors.inkMuted)
                }
            } else {
                Label(translate("playback.unavailable", [:]), systemImage: "waveform.slash")
                    .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted).padding(.vertical, 5)
            }
            if let error = playback.error { Text(error).font(ArcoTypography.small).foregroundStyle(.red) }
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: playback.following)
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let current = scrubbing ? draft : playback.position
            let progress = min(1, max(0, current / max(playback.duration, 0.01)))
            Canvas { context, size in
                let count = max(1, Int(size.width / 3))
                for index in 0..<count {
                    let fraction = (Double(index) + 0.5) / Double(count)
                    let sample = playback.waveform.isEmpty ? 0 : playback.waveform[min(playback.waveform.count - 1, Int(fraction * Double(playback.waveform.count)))]
                    let height = 2 + sample * 36
                    let rect = CGRect(x: CGFloat(index) * size.width / CGFloat(count), y: (size.height - height) / 2, width: 2, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(fraction <= progress ? Color(white: 0.32) : Color(white: 0.82)))
                }
                let x = size.width * progress
                context.fill(Path(roundedRect: CGRect(x: max(0, x - 1), y: 1, width: 2, height: size.height - 2), cornerRadius: 1), with: .color(ArcoNativeColors.brand))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                scrubbing = true
                draft = min(playback.duration, max(0, value.location.x / max(1, geometry.size.width) * playback.duration))
            }.onEnded { _ in playback.seek(draft); scrubbing = false })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(translate("playback.position", [:]))
            .accessibilityValue(clock(current))
            .accessibilityAdjustableAction { direction in
                playback.seek(playback.position + (direction == .increment ? 5 : -5))
            }
            .focusable()
            .onKeyPress(.leftArrow) { playback.seek(playback.position - 5); return .handled }
            .onKeyPress(.rightArrow) { playback.seek(playback.position + 5); return .handled }
        }.frame(height: 40)
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
