// Arco native recorder. ScreenCaptureKit captures system audio and
// AVAudioEngine captures the microphone. Audio is emitted as standard
// interleaved 16 kHz / signed 16-bit / stereo PCM on stdout:
// channel 0 (left) = system audio, channel 1 (right) = microphone.
//
// Usage: arco-recorder [both|system|mic]

import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import ScreenCaptureKit

private let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "both"
private let isSelfTest = mode == "--self-test"
private let useSystem = !isSelfTest && (mode == "both" || mode == "system")
private let useMic = !isSelfTest && (mode == "both" || mode == "mic")
private let sampleRate = 16_000
private let frameSize = 1_600 // 100 ms at 16 kHz
private let maxBufferedFrames = sampleRate * 3 // Hard 3-second FIFO per source.
private let qualityLogIntervalTicks = 100 // 10 seconds at the 100 ms mix cadence.

guard ["both", "system", "mic", "--self-test"].contains(mode) else {
    FileHandle.standardError.write(Data("invalid capture mode: \(mode)\n".utf8))
    exit(2)
}

private enum AudioResamplerError: Error, CustomStringConvertible {
    case invalidSampleRate(Double)
    case unsupportedFormat
    case conversionFailed(String)
    case alreadyFinished

    var description: String {
        switch self {
        case let .invalidSampleRate(rate): "invalid sample rate: \(rate)"
        case .unsupportedFormat: "AVAudioConverter could not create a mono float converter"
        case let .conversionFailed(message): "sample-rate conversion failed: \(message)"
        case .alreadyFinished: "sample-rate converter was already finished"
        }
    }
}

/// Stateful, band-limited sample-rate conversion. Keeping one converter per
/// capture source preserves filter history and fractional phase across hardware
/// callback boundaries instead of treating every 100 ms buffer as a new clip.
private final class StreamingAudioResampler {
    let sourceRate: Double
    let targetRate: Double
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var pendingInput: [Float] = []
    private var totalInputFrames = 0
    private var totalOutputFrames = 0
    private var finished = false

    init(sourceRate: Double, targetRate: Double) throws {
        guard sourceRate.isFinite, sourceRate > 0 else {
            throw AudioResamplerError.invalidSampleRate(sourceRate)
        }
        guard targetRate.isFinite, targetRate > 0 else {
            throw AudioResamplerError.invalidSampleRate(targetRate)
        }
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: 1,
                interleaved: false
            ),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw AudioResamplerError.unsupportedFormat
        }
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.primeMethod = .none
    }

    func convert(_ samples: [Float]) throws -> [Float] {
        guard !finished else { throw AudioResamplerError.alreadyFinished }
        guard !samples.isEmpty else { return [] }
        pendingInput.append(contentsOf: samples)
        totalInputFrames += samples.count

        let expectedFrames = Int(
            floor(Double(totalInputFrames) * targetRate / sourceRate)
        )
        let capacity = max(0, expectedFrames - totalOutputFrames)
        guard capacity > 0 else { return [] }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(capacity)
        ) else {
            throw AudioResamplerError.unsupportedFormat
        }
        var retainedBuffers: [AVAudioPCMBuffer] = []
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            [self] requestedPackets, inputStatus in
            guard !pendingInput.isEmpty else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            let count = min(max(1, Int(requestedPackets)), pendingInput.count)
            guard let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(count)
            ), let inputData = input.floatChannelData else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            input.frameLength = input.frameCapacity
            pendingInput.withUnsafeBufferPointer { source in
                inputData[0].update(from: source.baseAddress!, count: count)
            }
            pendingInput.removeFirst(count)
            retainedBuffers.append(input)
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error || conversionError != nil {
            throw AudioResamplerError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown AVAudioConverter error"
            )
        }
        let result = Self.samples(from: output)
        totalOutputFrames += result.count
        return result
    }

    func finish() throws -> [Float] {
        guard !finished else { return [] }
        finished = true
        let expectedFrames = Int(
            (Double(totalInputFrames) * targetRate / sourceRate).rounded()
        )
        let remaining = max(0, expectedFrames - totalOutputFrames)
        guard remaining > 0 else { return [] }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(remaining + 64)
        ) else {
            throw AudioResamplerError.unsupportedFormat
        }
        var retainedBuffers: [AVAudioPCMBuffer] = []
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            [self] requestedPackets, inputStatus in
            if pendingInput.isEmpty {
                inputStatus.pointee = .endOfStream
                return nil
            }
            let count = min(max(1, Int(requestedPackets)), pendingInput.count)
            guard let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(count)
            ), let inputData = input.floatChannelData else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            input.frameLength = input.frameCapacity
            pendingInput.withUnsafeBufferPointer { source in
                inputData[0].update(from: source.baseAddress!, count: count)
            }
            pendingInput.removeFirst(count)
            retainedBuffers.append(input)
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error || conversionError != nil {
            throw AudioResamplerError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown AVAudioConverter flush error"
            )
        }
        var result = Self.samples(from: output)
        if result.count > remaining {
            result.removeLast(result.count - remaining)
        }
        totalOutputFrames += result.count
        return result
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

private struct AudioQualitySnapshot {
    let frames: Int
    let rms: Double
    let peak: Double
    let clippedFrames: Int
    let paddedFrames: Int
    let underflowEvents: Int
    let droppedFrames: Int
}

private struct AudioQualityAccumulator {
    private var frames = 0
    private var sumSquares = 0.0
    private var peak = 0.0
    private var clippedFrames = 0
    private var paddedFrames = 0
    private var underflowEvents = 0
    private var droppedFrames = 0

    mutating func observe(
        samples: [Int16],
        paddedFrames: Int = 0,
        droppedFrames: Int = 0
    ) {
        frames += samples.count
        self.paddedFrames += max(0, paddedFrames)
        self.droppedFrames += max(0, droppedFrames)
        if paddedFrames > 0 {
            underflowEvents += 1
        }
        for sample in samples {
            let normalized = abs(Double(sample) / 32_768.0)
            sumSquares += normalized * normalized
            peak = max(peak, normalized)
            if sample == Int16.min || sample == Int16.max {
                clippedFrames += 1
            }
        }
    }

    mutating func recordDropped(_ count: Int) {
        droppedFrames += max(0, count)
    }

    func snapshot() -> AudioQualitySnapshot {
        AudioQualitySnapshot(
            frames: frames,
            rms: frames == 0 ? 0 : sqrt(sumSquares / Double(frames)),
            peak: peak,
            clippedFrames: clippedFrames,
            paddedFrames: paddedFrames,
            underflowEvents: underflowEvents,
            droppedFrames: droppedFrames
        )
    }

    mutating func takeSnapshot() -> AudioQualitySnapshot {
        let result = snapshot()
        self = AudioQualityAccumulator()
        return result
    }
}

private enum EchoCancellationPolicy {
    static func shouldEnable(mode: String, setting: String?) -> Bool {
        guard mode == "both" else { return false }
        // AVAudioEngine voice processing makes this process a system audio
        // "ducker" on macOS, which can reduce meeting playback from other
        // apps to near silence. Keep AEC available for explicit experiments,
        // but never enable that system-wide side effect by default.
        return setting?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "on"
    }
}

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var systemTapID = AudioObjectID(kAudioObjectUnknown)
    private var systemAggregateID = AudioObjectID(kAudioObjectUnknown)
    private var systemIOProcID: AudioDeviceIOProcID?
    private var systemFormat = AudioStreamBasicDescription()
    private var systemResampler: StreamingAudioResampler?
    private var microphoneResampler: StreamingAudioResampler?
    private var micEngine: AVAudioEngine?
    private var mixTimer: DispatchSourceTimer?
    private var parentMonitor: DispatchSourceTimer?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "app.arco.recorder")
    private let lifecycleQueue = DispatchQueue(label: "app.arco.recorder.lifecycle")
    private let lock = NSLock()
    private var systemBuffer: [Int16] = []
    private var micBuffer: [Int16] = []
    private var systemQuality = AudioQualityAccumulator()
    private var microphoneQuality = AudioQualityAccumulator()
    private var qualityTick = 0
    private var microphoneAECEnabled = false
    private var loggedFormats = Set<String>()
    private var systemCaptureStarted = !useSystem
    private var microphoneCaptureStarted = !useMic
    private var announcedReady = false
    private var hasStopped = false
    private let output = FileHandle.standardOutput

    func start() {
        installTerminationHandlers()
        startParentMonitor()
        startMixTimer()
        if useMic {
            startMicrophoneCapture()
        }
        if useSystem {
            startSystemCapture()
        }
        announceReadyIfNeeded()
    }

    private func installTerminationHandlers() {
        // Tauri stops its owned helper with SIGTERM. Convert that signal into
        // an orderly teardown so Core Audio does not retain stale tap/privacy
        // attribution after the helper disappears.
        installTerminationSignalHandler(SIGTERM)
        installTerminationSignalHandler(SIGINT)

        // The transcriber owns the read end of stdout. If it exits first,
        // write(2) must report EPIPE instead of killing this process before
        // the Core Audio resources can be released.
        signal(SIGPIPE, SIG_IGN)
    }

    private func installTerminationSignalHandler(_ signalNumber: Int32) {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: signalNumber,
            queue: lifecycleQueue
        )
        source.setEventHandler { [weak self] in
            self?.stopAndExit(
                0,
                reason: "received signal \(signalNumber); stopping native recorder"
            )
        }
        source.resume()
        terminationSignalSources.append(source)
    }

    private func startParentMonitor() {
        let rawPID = (ProcessInfo.processInfo.environment["ARCO_PARENT_PID"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPID = Int32(rawPID), parsedPID > 1 else { return }
        let parentPID = pid_t(parsedPID)
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(
            deadline: .now() + 0.5,
            repeating: 0.5,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard kill(parentPID, 0) != 0, errno == ESRCH else { return }
            self?.stopAndExit(
                0,
                reason: "Arco parent process exited; stopping native recorder"
            )
        }
        timer.resume()
        parentMonitor = timer
    }

    private func startSystemCapture() {
        if #available(macOS 14.2, *) {
            startCoreAudioTapCapture()
        } else {
            startScreenCaptureKitCapture()
        }
    }

    @available(macOS 14.2, *)
    private func startCoreAudioTapCapture() {
        log("starting Core Audio system tap")
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "Arco system audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let createTapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard createTapStatus == noErr else {
            fail("could not create Core Audio system tap: \(createTapStatus)")
        }
        systemTapID = tapID

        guard let tapUID = Self.stringProperty(kAudioTapPropertyUID, device: tapID) else {
            fail("could not read Core Audio system tap identifier")
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Arco system audio",
            kAudioAggregateDeviceUIDKey: "app.arco.desktop.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let createAggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard createAggregateStatus == noErr else {
            fail("could not create Core Audio aggregate device: \(createAggregateStatus)")
        }
        systemAggregateID = aggregateID

        // Follow Apple's Core Audio tap sample: create an empty aggregate
        // device first, then mutate its tap list. Supplying a hardware output
        // subdevice in the initial composition makes the HAL negotiate an
        // unnecessary output stream and can block IOProc registration.
        var tapListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapListSize: UInt32 = 0
        var tapList: CFArray?
        let tapListSizeStatus = AudioObjectGetPropertyDataSize(
            aggregateID,
            &tapListAddress,
            0,
            nil,
            &tapListSize
        )
        guard tapListSizeStatus == noErr else {
            fail("could not inspect Core Audio aggregate tap list: \(tapListSizeStatus)")
        }
        let readTapListStatus = withUnsafeMutablePointer(to: &tapList) { pointer in
            AudioObjectGetPropertyData(
                aggregateID,
                &tapListAddress,
                0,
                nil,
                &tapListSize,
                pointer
            )
        }
        guard readTapListStatus == noErr else {
            fail("could not read Core Audio aggregate tap list: \(readTapListStatus)")
        }
        var tapUIDs = tapList as? [CFString] ?? []
        tapUIDs.append(tapUID as CFString)
        tapList = tapUIDs as CFArray
        tapListSize += UInt32(MemoryLayout<CFString>.stride)
        let setTapListStatus = withUnsafeMutablePointer(to: &tapList) { pointer in
            AudioObjectSetPropertyData(
                aggregateID,
                &tapListAddress,
                0,
                nil,
                tapListSize,
                pointer
            )
        }
        guard setTapListStatus == noErr else {
            fail("could not attach Core Audio tap to aggregate device: \(setTapListStatus)")
        }

        guard let format = Self.waitForStreamFormat(for: aggregateID) else {
            fail("could not read Core Audio system tap format")
        }
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            fail("Core Audio system tap returned an invalid format")
        }
        log(
            "system tap format sampleRate=\(format.mSampleRate) "
                + "channels=\(format.mChannelsPerFrame) "
                + "bits=\(format.mBitsPerChannel) flags=\(format.mFormatFlags)"
        )
        systemFormat = format
        do {
            systemResampler = try StreamingAudioResampler(
                sourceRate: format.mSampleRate,
                targetRate: Double(sampleRate)
            )
        } catch {
            fail("could not configure system sample-rate converter: \(error)")
        }

        log("registering Core Audio system tap IO callback")
        var ioProcID: AudioDeviceIOProcID?
        let createIOStatus = AudioDeviceCreateIOProcID(
            aggregateID,
            arcoAudioDeviceIOProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &ioProcID
        )
        guard createIOStatus == noErr, let ioProcID else {
            fail("could not create Core Audio system tap IO callback: \(createIOStatus)")
        }
        systemIOProcID = ioProcID

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            systemIOProcID = nil
            fail("could not start Core Audio system tap: \(startStatus)")
        }
        log("system audio capture started with Core Audio tap")
        markSystemCaptureStarted()
    }

    fileprivate func consumeSystemAudio(
        _ inputData: UnsafePointer<AudioBufferList>?
    ) {
        guard let inputData,
              let mono = Self.extractMono(inputData, format: systemFormat),
              let resampler = systemResampler
        else { return }
        let pcm: [Int16]
        do {
            pcm = Self.floatToInt16(try resampler.convert(mono))
        } catch {
            log("system sample-rate conversion failed: \(error)")
            return
        }
        lock.lock()
        let dropped = Self.appendBounded(pcm, to: &systemBuffer)
        systemQuality.recordDropped(dropped)
        lock.unlock()
    }

    private func startScreenCaptureKitCapture() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.current
                self.configureScreenCaptureKit(with: content)
            } catch {
                self.fail("could not enumerate displays: \(error)")
            }
        }
    }

    private func configureScreenCaptureKit(with content: SCShareableContent) {
        guard let display = content.displays.first else {
            fail("no display is available (check Screen Recording permission)")
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
                sampleHandlerQueue: queue
            )
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: queue
            )
        } catch {
            fail("could not add ScreenCaptureKit output: \(error)")
        }
        stream.startCapture { [weak self] error in
            guard let self else { return }
            if let error {
                self.fail("could not start system audio capture: \(error)")
            }
        }
        // ScreenCaptureKit has already accepted the stream and installed its
        // remote queues when startCapture returns. On macOS 27 beta the
        // completion handler can remain pending even while audio is flowing,
        // so it cannot serve as the recorder readiness handshake. Any later
        // startup failure still terminates the helper through the completion
        // handler or SCStreamDelegate.
        markSystemCaptureStarted()
    }

    private func startMicrophoneCapture() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        configureMicrophone(input)
        let aecSetting = ProcessInfo.processInfo.environment["ARCO_MIC_ECHO_CANCELLATION"]
        if EchoCancellationPolicy.shouldEnable(mode: mode, setting: aecSetting) {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Platform AEC is useful for speaker leakage; avoid adding a
                // second gain/noise-processing stage before Deepgram.
                input.isVoiceProcessingAGCEnabled = false
                microphoneAECEnabled = true
                log("microphone platform echo cancellation enabled (AGC disabled)")
            } catch {
                microphoneAECEnabled = false
                log("microphone echo cancellation unavailable; continuing raw: \(error)")
            }
        } else {
            log("microphone echo cancellation bypassed (mode=\(mode))")
        }
        let format = input.outputFormat(forBus: 0)
        let channelCount = max(1, Int(format.channelCount))
        log(
            "microphone format sampleRate=\(format.sampleRate) "
                + "channels=\(channelCount)"
        )
        let resampler: StreamingAudioResampler
        do {
            resampler = try StreamingAudioResampler(
                sourceRate: format.sampleRate,
                targetRate: Double(sampleRate)
            )
            microphoneResampler = resampler
        } catch {
            fail("could not configure microphone sample-rate converter: \(error)")
        }
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
            let pcm: [Int16]
            do {
                pcm = Self.floatToInt16(try resampler.convert(mono))
            } catch {
                self.log("microphone sample-rate conversion failed: \(error)")
                return
            }
            self.lock.lock()
            let dropped = Self.appendBounded(pcm, to: &self.micBuffer)
            self.microphoneQuality.recordDropped(dropped)
            self.lock.unlock()
        }

        do {
            engine.prepare()
            try engine.start()
            micEngine = engine
            log("microphone capture started")
            markMicrophoneCaptureStarted()
        } catch {
            fail("could not start microphone capture: \(error)")
        }
    }

    private func markSystemCaptureStarted() {
        lock.lock()
        systemCaptureStarted = true
        lock.unlock()
        announceReadyIfNeeded()
    }

    private func markMicrophoneCaptureStarted() {
        lock.lock()
        microphoneCaptureStarted = true
        lock.unlock()
        announceReadyIfNeeded()
    }

    private func announceReadyIfNeeded() {
        lock.lock()
        let shouldAnnounce = systemCaptureStarted
            && microphoneCaptureStarted
            && !announcedReady
        if shouldAnnounce {
            announcedReady = true
        }
        lock.unlock()
        guard shouldAnnounce else { return }
        writeReadySignalIfRequested()
        log("recorder started (mode=\(mode))")
        log("ARCO_RECORDER_STARTED: \(mode)")
    }

    private func writeReadySignalIfRequested() {
        let path = (ProcessInfo.processInfo.environment["ARCO_RECORDER_READY_FILE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        do {
            try Data("ready\n".utf8).write(
                to: URL(fileURLWithPath: path),
                options: .atomic
            )
        } catch {
            fail("could not publish recorder readiness: \(error)")
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
        let systemSamples = systemCount > 0 ? Array(systemBuffer.prefix(systemCount)) : []
        let microphoneSamples = micCount > 0 ? Array(micBuffer.prefix(micCount)) : []
        var interleaved = [Int16](repeating: 0, count: frameSize * 2)
        for index in 0 ..< systemCount {
            interleaved[index * 2] = systemSamples[index]
        }
        for index in 0 ..< micCount {
            interleaved[index * 2 + 1] = microphoneSamples[index]
        }
        if systemCount > 0 {
            systemBuffer.removeFirst(systemCount)
        }
        if micCount > 0 {
            micBuffer.removeFirst(micCount)
        }
        if useSystem {
            systemQuality.observe(
                samples: systemSamples,
                paddedFrames: frameSize - systemCount
            )
        }
        if useMic {
            microphoneQuality.observe(
                samples: microphoneSamples,
                paddedFrames: frameSize - micCount
            )
        }
        qualityTick += 1
        let shouldLogQuality = qualityTick >= qualityLogIntervalTicks
        let systemSnapshot = shouldLogQuality && useSystem
            ? systemQuality.takeSnapshot()
            : nil
        let microphoneSnapshot = shouldLogQuality && useMic
            ? microphoneQuality.takeSnapshot()
            : nil
        if shouldLogQuality {
            qualityTick = 0
        }
        lock.unlock()

        if let systemSnapshot {
            logQuality(source: "system", snapshot: systemSnapshot, aec: false)
        }
        if let microphoneSnapshot {
            logQuality(
                source: "microphone",
                snapshot: microphoneSnapshot,
                aec: microphoneAECEnabled
            )
        }

        // Emit even during silence so channel alignment remains stable from
        // process start through permission prompts and transient device gaps.
        let emitted = interleaved.withUnsafeBytes { bytes in
            writeAll(bytes)
        }
        if !emitted {
            stopAndExit(
                0,
                reason: "audio consumer closed; stopping native recorder"
            )
        }
    }

    private func logQuality(
        source: String,
        snapshot: AudioQualitySnapshot,
        aec: Bool
    ) {
        log(
            String(
                format: "ARCO_AUDIO_QUALITY source=%@ frames=%d rms=%.6f peak=%.6f clipped=%d padded=%d underflows=%d dropped=%d aec=%@",
                source,
                snapshot.frames,
                snapshot.rms,
                snapshot.peak,
                snapshot.clippedFrames,
                snapshot.paddedFrames,
                snapshot.underflowEvents,
                snapshot.droppedFrames,
                aec ? "on" : "off"
            )
        )
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard var pointer = bytes.baseAddress else { return true }
        var remaining = bytes.count
        let descriptor = output.fileDescriptor
        while remaining > 0 {
            let written = Darwin.write(descriptor, pointer, remaining)
            if written > 0 {
                remaining -= written
                pointer = pointer.advanced(by: written)
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            return false
        }
        return true
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
        guard let extracted = Self.extractMono(sampleBuffer) else { return }
        if systemResampler == nil
            || abs((systemResampler?.sourceRate ?? 0) - extracted.sampleRate) > 1
        {
            do {
                systemResampler = try StreamingAudioResampler(
                    sourceRate: extracted.sampleRate,
                    targetRate: Double(sampleRate)
                )
            } catch {
                log("could not configure system sample-rate converter: \(error)")
                return
            }
        }
        guard let systemResampler else { return }
        let pcm: [Int16]
        do {
            pcm = Self.floatToInt16(try systemResampler.convert(extracted.samples))
        } catch {
            log("system sample-rate conversion failed: \(error)")
            return
        }
        lock.lock()
        let dropped = Self.appendBounded(pcm, to: &systemBuffer)
        systemQuality.recordDropped(dropped)
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

    private static func extractMono(
        _ sampleBuffer: CMSampleBuffer
    ) -> (samples: [Float], sampleRate: Double)? {
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
        return (mono, format.mSampleRate)
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

    private static func streamFormat(
        for device: AudioDeviceID
    ) -> AudioStreamBasicDescription? {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device,
            &streamsAddress,
            0,
            nil,
            &streamsSize
        ) == noErr else { return nil }
        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else { return nil }

        var streams = [AudioStreamID](repeating: 0, count: streamCount)
        guard AudioObjectGetPropertyData(
            device,
            &streamsAddress,
            0,
            nil,
            &streamsSize,
            &streams
        ) == noErr else { return nil }

        for stream in streams {
            var directionAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyDirection,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var direction: UInt32 = 0
            var directionSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                stream,
                &directionAddress,
                0,
                nil,
                &directionSize,
                &direction
            ) == noErr, direction == 1 else { continue }

            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioObjectGetPropertyData(
                stream,
                &formatAddress,
                0,
                nil,
                &formatSize,
                &format
            ) == noErr {
                return format
            }
        }
        return nil
    }

    private static func waitForStreamFormat(
        for device: AudioDeviceID,
        timeout: TimeInterval = 2
    ) -> AudioStreamBasicDescription? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let format = streamFormat(for: device) {
                return format
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return nil
    }

    private static func extractMono(
        _ audioBuffers: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> [Float]? {
        let flags = format.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let bits = Int(format.mBitsPerChannel)
        guard (isFloat && bits == 32) || (isSignedInteger && bits == 16) else {
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBuffers)
        )
        let bytesPerSample = bits / 8
        let frameCount = buffers.compactMap { buffer -> Int? in
            guard buffer.mData != nil, buffer.mNumberChannels > 0 else { return nil }
            return Int(buffer.mDataByteSize)
                / bytesPerSample
                / Int(buffer.mNumberChannels)
        }.min() ?? 0
        guard frameCount > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        var channelCount = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            channelCount += channels
            if isFloat {
                let samples = data.bindMemory(
                    to: Float32.self,
                    capacity: frameCount * channels
                )
                for frame in 0 ..< frameCount {
                    for channel in 0 ..< channels {
                        mono[frame] += samples[frame * channels + channel]
                    }
                }
            } else {
                let samples = data.bindMemory(
                    to: Int16.self,
                    capacity: frameCount * channels
                )
                for frame in 0 ..< frameCount {
                    for channel in 0 ..< channels {
                        mono[frame] += Float(samples[frame * channels + channel]) / 32_768.0
                    }
                }
            }
        }
        guard channelCount > 0 else { return nil }
        if channelCount > 1 {
            for frame in 0 ..< frameCount {
                mono[frame] /= Float(channelCount)
            }
        }
        return mono
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
    ) -> Int {
        guard !samples.isEmpty else { return 0 }
        if samples.count >= maxBufferedFrames {
            let dropped = buffer.count + samples.count - maxBufferedFrames
            buffer = Array(samples.suffix(maxBufferedFrames))
            return dropped
        }
        buffer.append(contentsOf: samples)
        let overflow = buffer.count - maxBufferedFrames
        if overflow > 0 {
            // Keep the freshest aligned audio. This prevents permission stalls,
            // device bursts, or stdout backpressure from growing memory forever.
            buffer.removeFirst(overflow)
        }
        return max(0, overflow)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func stopAndExit(_ status: Int32, reason: String) -> Never {
        log(reason)
        stop()
        exit(status)
    }

    private func stop() {
        lock.lock()
        guard !hasStopped else {
            lock.unlock()
            return
        }
        hasStopped = true
        lock.unlock()

        mixTimer?.cancel()
        mixTimer = nil
        parentMonitor?.cancel()
        parentMonitor = nil
        for source in terminationSignalSources {
            source.cancel()
        }
        terminationSignalSources.removeAll()

        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micEngine = nil
        }

        if #available(macOS 14.2, *) {
            stopCoreAudioTapCapture()
        }

        if let stream {
            let semaphore = DispatchSemaphore(value: 0)
            stream.stopCapture { error in
                if let error {
                    self.log("could not stop ScreenCaptureKit capture cleanly: \(error)")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
            self.stream = nil
        }
    }

    @available(macOS 14.2, *)
    private func stopCoreAudioTapCapture() {
        let aggregateID = systemAggregateID
        if aggregateID != AudioObjectID(kAudioObjectUnknown),
           let ioProcID = systemIOProcID
        {
            let stopStatus = AudioDeviceStop(aggregateID, ioProcID)
            if stopStatus != noErr {
                log("could not stop Core Audio system tap: \(stopStatus)")
            }
            let destroyIOStatus = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            if destroyIOStatus != noErr {
                log("could not destroy Core Audio IO callback: \(destroyIOStatus)")
            }
            systemIOProcID = nil
        }

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            let destroyAggregateStatus = AudioHardwareDestroyAggregateDevice(aggregateID)
            if destroyAggregateStatus != noErr {
                log("could not destroy Core Audio aggregate device: \(destroyAggregateStatus)")
            }
            systemAggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        let tapID = systemTapID
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let destroyTapStatus = AudioHardwareDestroyProcessTap(tapID)
            if destroyTapStatus != noErr {
                log("could not destroy Core Audio process tap: \(destroyTapStatus)")
            }
            systemTapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func fail(_ message: String) -> Never {
        log(message)
        stop()
        exit(1)
    }
}

private let arcoAudioDeviceIOProc: AudioDeviceIOProc = {
    _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let recorder = Unmanaged<Recorder>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    recorder.consumeSystemAudio(inputData)
    return noErr
}

private enum RecorderSelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private func selfTestRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw RecorderSelfTestError.failed(message)
    }
}

private func sineWave(frequency: Double, sampleRate: Double, count: Int) -> [Float] {
    (0 ..< count).map { index in
        Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
    }
}

private func normalizedRMS(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return 0 }
    return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
}

private func runRecorderSelfTests() throws {
    do {
        _ = try StreamingAudioResampler(sourceRate: 0, targetRate: 16_000)
        throw RecorderSelfTestError.failed("zero source sample rate was accepted")
    } catch let error as RecorderSelfTestError {
        throw error
    } catch {
        // Expected: invalid hardware formats must be rejected before capture.
    }

    let source = sineWave(frequency: 1_000, sampleRate: 48_000, count: 48_000)
    let resampler = try StreamingAudioResampler(sourceRate: 48_000, targetRate: 16_000)
    var converted: [Float] = []
    var convertedChunkCounts: [Int] = []
    var offset = 0
    for chunkSize in [997, 4_801, 127, 8_113, 16_003, 17_959] {
        let end = min(source.count, offset + chunkSize)
        if end > offset {
            let chunk = try resampler.convert(Array(source[offset ..< end]))
            convertedChunkCounts.append(chunk.count)
            converted += chunk
            offset = end
        }
    }
    let emptyOutput = try resampler.convert([])
    try selfTestRequire(emptyOutput.isEmpty, "empty input emitted audio")
    converted += try resampler.finish()
    try selfTestRequire(offset == source.count, "self-test did not consume the full input signal")
    try selfTestRequire(
        (15_936 ... 16_000).contains(converted.count),
        "48 kHz to 16 kHz produced \(converted.count) frames"
    )
    let outputRMS = normalizedRMS(converted)
    try selfTestRequire(outputRMS > 0.65 && outputRMS < 0.75, "1 kHz tone RMS was \(outputRMS)")
    let largestStep = converted.indices.dropFirst().map { index in
        (index, abs(Double(converted[index] - converted[index - 1])))
    }.max { $0.1 < $1.1 } ?? (0, 0)
    try selfTestRequire(
        largestStep.1 < 0.5,
        "chunked resampling introduced a discontinuity (index=\(largestStep.0), step=\(largestStep.1), chunks=\(convertedChunkCounts))"
    )
    let upwardZeroCrossings = zip(converted.dropFirst(), converted)
        .filter { $0.1 <= 0.1 && $0.0 > 0.1 }
        .count
    try selfTestRequire(
        (985 ... 1_001).contains(upwardZeroCrossings),
        "1 kHz tone produced \(upwardZeroCrossings) upward zero crossings"
    )
    let aliasSource = sineWave(frequency: 12_000, sampleRate: 48_000, count: 48_000)
    let aliasResampler = try StreamingAudioResampler(sourceRate: 48_000, targetRate: 16_000)
    let aliasOutput = try aliasResampler.convert(aliasSource) + aliasResampler.finish()
    let aliasRMS = normalizedRMS(Array(aliasOutput.dropFirst(min(256, aliasOutput.count))))
    try selfTestRequire(
        (15_936 ... 16_000).contains(aliasOutput.count),
        "anti-alias test produced the wrong frame count"
    )
    try selfTestRequire(aliasRMS < 0.05, "12 kHz content aliased into 16 kHz output (rms=\(aliasRMS))")

    var quality = AudioQualityAccumulator()
    quality.observe(samples: [0, 16_384, 32_767, -32_768], paddedFrames: 3, droppedFrames: 2)
    let snapshot = quality.snapshot()
    try selfTestRequire(snapshot.frames == 4, "quality meter counted \(snapshot.frames) frames")
    try selfTestRequire(snapshot.clippedFrames == 2, "quality meter counted \(snapshot.clippedFrames) clipped frames")
    try selfTestRequire(snapshot.paddedFrames == 3, "quality meter lost padded-frame telemetry")
    try selfTestRequire(snapshot.underflowEvents == 1, "quality meter lost the underflow event")
    try selfTestRequire(snapshot.droppedFrames == 2, "quality meter lost dropped-frame telemetry")
    try selfTestRequire(abs(snapshot.peak - 1.0) < 0.000_001, "quality peak was \(snapshot.peak)")
    try selfTestRequire(abs(snapshot.rms - 0.749_989_827) < 0.000_001, "quality RMS was \(snapshot.rms)")

    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "both", setting: nil), "both mode enabled ducking AEC without explicit opt-in")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "mic", setting: nil), "mic-only mode enabled AEC")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "both", setting: "off"), "explicit AEC off was ignored")
    try selfTestRequire(EchoCancellationPolicy.shouldEnable(mode: "both", setting: "on"), "explicit AEC on was ignored")
    try selfTestRequire(EchoCancellationPolicy.shouldEnable(mode: "both", setting: " ON "), "normalized AEC opt-in was ignored")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "both", setting: ""), "empty AEC setting enabled ducking AEC")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "both", setting: "unexpected"), "unknown AEC setting enabled ducking AEC")

    FileHandle.standardError.write(Data("ARCO_RECORDER_SELF_TEST_OK\n".utf8))
}

if isSelfTest {
    do {
        try runRecorderSelfTests()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("ARCO_RECORDER_SELF_TEST_FAILED: \(error)\n".utf8))
        exit(1)
    }
} else {
    let recorder = Recorder()
    recorder.start()
    RunLoop.main.run()
}
