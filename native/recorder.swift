// Arco native recorder. ScreenCaptureKit captures system audio and
// AVAudioEngine captures the microphone. Audio is emitted as standard
// interleaved 16 kHz / signed 16-bit / stereo PCM on stdout:
// channel 0 (left) = system audio, channel 1 (right) = microphone.
//
// Usage: arco-recorder [both|system|mic]

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ScreenCaptureKit

private let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "both"
private let useSystem = mode == "both" || mode == "system"
private let useMic = mode == "both" || mode == "mic"
private let sampleRate = 16_000
private let frameSize = 1_600 // 100 ms at 16 kHz
private let maxBufferedFrames = sampleRate * 3 // Hard 3-second FIFO per source.

guard ["both", "system", "mic"].contains(mode) else {
    FileHandle.standardError.write(Data("invalid capture mode: \(mode)\n".utf8))
    exit(2)
}

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var mixTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.arco.recorder")
    private let lock = NSLock()
    private var systemBuffer: [Int16] = []
    private var micBuffer: [Int16] = []
    private var loggedFormats = Set<String>()
    private let output = FileHandle.standardOutput

    func start() {
        startMixTimer()
        if useMic {
            startMicrophoneCapture()
        }
        if useSystem {
            startSystemCapture()
        } else {
            log("recorder started (mode=\(mode))")
        }
    }

    private func startSystemCapture() {
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) { [weak self] content, error in
            guard let self else { return }
            if let error {
                self.fail("could not enumerate displays: \(error)")
            }
            guard let display = content?.displays.first else {
                self.fail("no display is available (check Screen Recording permission)")
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = sampleRate
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
            // ScreenCaptureKit requires a screen output for audio to flow. The
            // two-pixel, one-frame-per-second stream keeps its cost negligible.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false

            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )
            self.stream = stream
            do {
                try stream.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: self.queue
                )
                try stream.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: self.queue
                )
            } catch {
                self.fail("could not add ScreenCaptureKit output: \(error)")
            }
            stream.startCapture { error in
                if let error {
                    self.fail("could not start system audio capture: \(error)")
                }
                self.log("recorder started (mode=\(mode))")
            }
        }
    }

    private func startMicrophoneCapture() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        configureMicrophone(input)
        let format = input.outputFormat(forBus: 0)
        let channelCount = max(1, Int(format.channelCount))
        log(
            "microphone format sampleRate=\(format.sampleRate) "
                + "channels=\(channelCount)"
        )
        input.installTap(
            onBus: 0,
            bufferSize: 4_800,
            format: format
        ) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else {
                return
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0 ..< channelCount {
                let samples = channelData[channel]
                for frame in 0 ..< frames {
                    mono[frame] += samples[frame]
                }
            }
            if channelCount > 1 {
                for frame in 0 ..< frames {
                    mono[frame] /= Float(channelCount)
                }
            }
            let pcm = Self.floatToInt16(
                Self.resample(mono, from: format.sampleRate)
            )
            self.lock.lock()
            Self.appendBounded(pcm, to: &self.micBuffer)
            self.lock.unlock()
        }

        do {
            engine.prepare()
            try engine.start()
            micEngine = engine
            log("microphone capture started")
        } catch {
            fail("could not start microphone capture: \(error)")
        }
    }

    private func configureMicrophone(_ input: AVAudioInputNode) {
        let environment = ProcessInfo.processInfo.environment
        let requestedID = (environment["ARCO_MIC_DEVICE_ID"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = (environment["ARCO_MIC_DEVICE_NAME"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedID.isEmpty else {
            if let device = AVCaptureDevice.default(for: .audio) {
                log("using default microphone: \(device.localizedName)")
            }
            return
        }
        guard var deviceID = Self.audioDeviceID(forUID: requestedID) else {
            log("configured microphone was not found; using system default")
            return
        }
        guard let audioUnit = input.audioUnit else {
            log("microphone audio unit unavailable; using system default")
            return
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            let label = requestedName.isEmpty ? requestedID : requestedName
            log("using configured microphone: \(label)")
        } else {
            log("could not select configured microphone; using system default")
        }
    }

    private func startMixTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.mixAndEmit()
        }
        timer.resume()
        mixTimer = timer
    }

    private func mixAndEmit() {
        lock.lock()
        // Drain both FIFO queues on the same 100 ms clock. A late or disabled
        // source is represented by zeroes, never by shifting the other channel
        // in time and never by summing both speakers into one sample.
        let systemCount = useSystem ? min(frameSize, systemBuffer.count) : 0
        let micCount = useMic ? min(frameSize, micBuffer.count) : 0
        var interleaved = [Int16](repeating: 0, count: frameSize * 2)
        for index in 0 ..< systemCount {
            interleaved[index * 2] = systemBuffer[index]
        }
        for index in 0 ..< micCount {
            interleaved[index * 2 + 1] = micBuffer[index]
        }
        if systemCount > 0 {
            systemBuffer.removeFirst(systemCount)
        }
        if micCount > 0 {
            micBuffer.removeFirst(micCount)
        }
        lock.unlock()

        // Emit even during silence so channel alignment remains stable from
        // process start through permission prompts and transient device gaps.
        interleaved.withUnsafeBytes { bytes in
            output.write(Data(bytes))
        }
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // The room microphone is captured separately through AVAudioEngine.
        // This SCStream output therefore accepts system audio only; avoiding
        // SCStreamOutputType.microphone keeps the helper compatible with
        // macOS 14, where that enum case does not exist yet.
        guard type == .audio, sampleBuffer.isValid else {
            return
        }
        logAudioFormatOnce(sampleBuffer, source: "system")
        guard let pcm = Self.extractInt16(sampleBuffer) else { return }
        lock.lock()
        Self.appendBounded(pcm, to: &systemBuffer)
        lock.unlock()
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        fail("system audio stream stopped: \(error)")
    }

    private func logAudioFormatOnce(
        _ sampleBuffer: CMSampleBuffer,
        source: String
    ) {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return }
        let format = pointer.pointee
        let key = "\(source)-\(format.mSampleRate)-\(format.mChannelsPerFrame)"
        guard !loggedFormats.contains(key) else { return }
        loggedFormats.insert(key)
        log(
            "audio source=\(source) sampleRate=\(format.mSampleRate) "
                + "channels=\(format.mChannelsPerFrame) bits=\(format.mBitsPerChannel)"
        )
    }

    private static func extractInt16(_ sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }
        let format = pointer.pointee
        var blockBuffer: CMBlockBuffer?
        var audioBuffers = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBuffers,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBuffers)
        guard let buffer = buffers.first, let data = buffer.mData else { return nil }
        let flags = format.mFormatFlags
        let channels = max(1, Int(format.mChannelsPerFrame))
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let bits = Int(format.mBitsPerChannel)
        var mono: [Float] = []

        if isFloat, bits == 32 {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let samples = data.bindMemory(to: Float32.self, capacity: count)
            let frames = count / channels
            mono.reserveCapacity(frames)
            for frame in 0 ..< frames {
                var sum: Float = 0
                for channel in 0 ..< channels {
                    sum += samples[frame * channels + channel]
                }
                mono.append(sum / Float(channels))
            }
        } else if isSignedInteger, bits == 16 {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = data.bindMemory(to: Int16.self, capacity: count)
            let frames = count / channels
            mono.reserveCapacity(frames)
            for frame in 0 ..< frames {
                var sum: Float = 0
                for channel in 0 ..< channels {
                    sum += Float(samples[frame * channels + channel]) / 32_768.0
                }
                mono.append(sum / Float(channels))
            }
        } else {
            return nil
        }
        return floatToInt16(resample(mono, from: format.mSampleRate))
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return nil }
        return devices.first { device in
            stringProperty(kAudioDevicePropertyDeviceUID, device: device) == uid
        }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device,
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String : nil
    }

    private static func floatToInt16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped < 0 ? clamped * 32_768.0 : clamped * 32_767.0)
        }
    }

    private static func appendBounded(
        _ samples: [Int16],
        to buffer: inout [Int16]
    ) {
        guard !samples.isEmpty else { return }
        if samples.count >= maxBufferedFrames {
            buffer = Array(samples.suffix(maxBufferedFrames))
            return
        }
        buffer.append(contentsOf: samples)
        let overflow = buffer.count - maxBufferedFrames
        if overflow > 0 {
            // Keep the freshest aligned audio. This prevents permission stalls,
            // device bursts, or stdout backpressure from growing memory forever.
            buffer.removeFirst(overflow)
        }
    }

    private static func resample(
        _ samples: [Float],
        from sourceRate: Double
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sourceRate > 0, abs(sourceRate - Double(sampleRate)) > 1 else {
            return samples
        }
        let ratio = Double(sampleRate) / sourceRate
        let outputCount = max(1, Int(Double(samples.count) * ratio))
        var result = [Float](repeating: 0, count: outputCount)
        for index in 0 ..< outputCount {
            let position = Double(index) / ratio
            let sourceIndex = Int(position)
            let fraction = Float(position - Double(sourceIndex))
            if sourceIndex + 1 < samples.count {
                result[index] = samples[sourceIndex] * (1 - fraction)
                    + samples[sourceIndex + 1] * fraction
            } else {
                result[index] = samples[samples.count - 1]
            }
        }
        return result
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }
}

let recorder = Recorder()
recorder.start()
RunLoop.main.run()
