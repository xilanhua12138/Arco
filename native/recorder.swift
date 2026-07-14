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
    private var systemTapID = AudioObjectID(kAudioObjectUnknown)
    private var systemAggregateID = AudioObjectID(kAudioObjectUnknown)
    private var systemIOProcID: AudioDeviceIOProcID?
    private var systemFormat = AudioStreamBasicDescription()
    private var micEngine: AVAudioEngine?
    private var mixTimer: DispatchSourceTimer?
    private var parentMonitor: DispatchSourceTimer?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "app.arco.recorder")
    private let lifecycleQueue = DispatchQueue(label: "app.arco.recorder.lifecycle")
    private let lock = NSLock()
    private var systemBuffer: [Int16] = []
    private var micBuffer: [Int16] = []
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
              let pcm = Self.extractInt16(inputData, format: systemFormat)
        else { return }
        lock.lock()
        Self.appendBounded(pcm, to: &systemBuffer)
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

    private static func extractInt16(
        _ audioBuffers: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) -> [Int16]? {
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
        return floatToInt16(resample(mono, from: format.mSampleRate))
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

let recorder = Recorder()
recorder.start()
RunLoop.main.run()
