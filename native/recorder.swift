// Arco native recorder. ScreenCaptureKit captures system audio and
// a monitored Core Audio device captures the microphone. Audio is emitted as standard
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
private let realtimeBufferDuration = 0.5 // Bound stale raw capture to 500 ms.
private let maxBufferedFrames = sampleRate * 3 // Hard 3-second FIFO per source.
private let qualityLogIntervalTicks = 100 // 10 seconds at the 100 ms mix cadence.

guard ["both", "system", "mic", "--self-test", "--check-microphone"].contains(mode) else {
    FileHandle.standardError.write(Data("invalid capture mode: \(mode)\n".utf8))
    exit(2)
}

private struct MicrophoneCandidate {
    let id: AudioDeviceID
    let uid: String
    let transport: UInt32
    let hasInput: Bool

    var usable: Bool {
        hasInput && uid != "BlackHole2ch_UID"
            && transport != kAudioDeviceTransportTypeVirtual
            && transport != kAudioDeviceTransportTypeAggregate
    }
}

private func chooseMicrophone(preferredUIDs: [String], devices: [MicrophoneCandidate]) -> MicrophoneCandidate? {
    let available = devices.filter(\.usable)
    for uid in preferredUIDs where !uid.isEmpty {
        if let match = available.first(where: { $0.uid == uid }) { return match }
    }
    return available.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) ?? available.first
}

/// No-data is a transport failure; zero-valued frames are valid silence.
/// All timestamps are monotonic, so sleep/wake and wall-clock changes cannot
/// produce a negative timeout. Owned by the ordinary audio processing queue.
private struct MicrophoneHealth {
    var lastFramesAt: TimeInterval = 0
    var streamStartedAt: TimeInterval = 0
    var hasFrames = false

    mutating func started(at now: TimeInterval) {
        streamStartedAt = now
        lastFramesAt = now
        hasFrames = false
    }

    mutating func received(frames: Int, at now: TimeInterval) {
        guard frames > 0 else { return }
        lastFramesAt = now
        hasFrames = true
    }

    func stalled(at now: TimeInterval) -> Bool { now - lastFramesAt >= 3 }
    func stable(at now: TimeInterval) -> Bool {
        hasFrames && !stalled(at: now) && now - streamStartedAt >= 5
    }

    static func retryDelay(failures: Int) -> TimeInterval {
        [5.0, 10.0, 30.0][min(2, max(0, failures - 1))]
    }
}

private enum MicrophoneRecoveryAction {
    case keep
    case reopen(MicrophoneCandidate?, reason: String)
}

private func microphoneRecoveryAction(
    devices: [MicrophoneCandidate], preferredUIDs: [String], currentID: AudioDeviceID,
    currentUID: String, hasStream: Bool, health: MicrophoneHealth,
    formatChanged: Bool, cooldowns: inout [String: TimeInterval], now: TimeInterval
) -> MicrophoneRecoveryAction {
    // An enumeration glitch must not tear down a stream still sending data.
    if devices.isEmpty, hasStream, !health.stalled(at: now) { return .keep }
    let current = devices.first { $0.id == currentID && $0.uid == currentUID }
    let stalled = hasStream && health.stalled(at: now)
    if stalled, current != nil, !formatChanged { cooldowns[currentUID] = now + 30 }
    let eligible = devices.filter { (cooldowns[$0.uid] ?? 0) <= now }
    let desired = chooseMicrophone(preferredUIDs: preferredUIDs, devices: eligible)
    let running = hasStream && current != nil && !stalled && !formatChanged
    if running, desired?.id == currentID || desired == nil { return .keep }
    return .reopen(desired, reason: stalled ? "no_frames" : formatChanged ? "format_changed" : "device_changed")
}

private func sameAudioFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
    a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID
        && a.mFormatFlags == b.mFormatFlags && a.mBytesPerPacket == b.mBytesPerPacket
        && a.mFramesPerPacket == b.mFramesPerPacket && a.mBytesPerFrame == b.mBytesPerFrame
        && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
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

    mutating func observeInterleaved(
        samples: [Int16],
        channel: Int,
        actualFrames: Int,
        paddedFrames: Int
    ) {
        frames += actualFrames
        self.paddedFrames += max(0, paddedFrames)
        if paddedFrames > 0 {
            underflowEvents += 1
        }
        guard actualFrames > 0 else { return }
        for frame in 0 ..< actualFrames {
            let sample = samples[frame * 2 + channel]
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
        // Use software AEC3 with the system channel as reference. Never enable
        // AVAudioEngine voice processing: it also ducks other apps' playback.
        return setting?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() != "off"
    }
}

private enum ParentAudioExclusionPolicy {
    static func isRequested(environment: [String: String]) -> Bool {
        environment["ARCO_EXCLUDE_PARENT_AUDIO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func parentPID(environment: [String: String]) -> pid_t? {
        guard isRequested(environment: environment) else { return nil }
        let rawPID = (environment["ARCO_PARENT_PID"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPID = Int32(rawPID), parsedPID > 1 else { return nil }
        return pid_t(parsedPID)
    }
}

/// Queue-confined PCM FIFO. The Rust audio runtime owns every real-time ring
/// and resampler; this queue only smooths ordinary-worker scheduling jitter.
private struct PCMSampleFIFO {
    private var storage: [Int16]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = [Int16](repeating: 0, count: capacity)
    }

    mutating func append(_ samples: [Int16]) -> Int {
        samples.withUnsafeBufferPointer { append($0) }
    }

    mutating func append(_ samples: UnsafeBufferPointer<Int16>) -> Int {
        guard !samples.isEmpty else { return 0 }
        let capacity = storage.count
        if samples.count >= capacity {
            let dropped = count + samples.count - capacity
            let start = samples.count - capacity
            for index in 0 ..< capacity {
                storage[index] = samples[start + index]
            }
            head = 0
            count = capacity
            return dropped
        }

        let overflow = max(0, count + samples.count - capacity)
        if overflow > 0 {
            head = (head + overflow) % capacity
            count -= overflow
        }
        for sample in samples {
            storage[(head + count) % capacity] = sample
            count += 1
        }
        return overflow
    }

    /// Shutdown is no longer a real-time path. Grow instead of discarding the
    /// oldest queued audio when the resampler publishes its final partial
    /// chunk after the ordinary bounded FIFO is already full.
    mutating func appendPreservingAll(_ samples: [Int16]) -> Int {
        guard !samples.isEmpty else { return 0 }
        let requiredCapacity = count + samples.count
        let oldCapacity = storage.count
        if requiredCapacity > oldCapacity {
            let newCapacity = max(requiredCapacity, oldCapacity * 2)
            var expanded = [Int16](repeating: 0, count: newCapacity)
            for index in 0 ..< count {
                expanded[index] = storage[(head + index) % oldCapacity]
            }
            storage = expanded
            head = 0
        }
        let dropped = append(samples)
        precondition(dropped == 0, "shutdown PCM FIFO unexpectedly discarded audio")
        return max(0, storage.count - oldCapacity)
    }

    mutating func drain(
        into output: inout [Int16],
        channel: Int,
        maxFrames: Int
    ) -> Int {
        let drained = min(maxFrames, count)
        guard drained > 0 else { return 0 }
        for index in 0 ..< drained {
            output[index * 2 + channel] = storage[(head + index) % storage.count]
        }
        head = (head + drained) % storage.count
        count -= drained
        return drained
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }
}

private struct AlignedPCMChunk {
    let samples: [Int16]
    let systemFrames: Int
    let microphoneFrames: Int
}

/// Drain only the frames still queued at shutdown. The longer source defines
/// the chunk duration; a shorter or disabled source is padded with zeroes so
/// system audio always remains left and microphone audio always remains right.
private func drainAlignedPCMChunk(
    systemBuffer: inout PCMSampleFIFO,
    microphoneBuffer: inout PCMSampleFIFO,
    includeSystem: Bool,
    includeMicrophone: Bool,
    maxFrames: Int
) -> AlignedPCMChunk? {
    precondition(maxFrames > 0)
    let availableSystem = includeSystem ? systemBuffer.count : 0
    let availableMicrophone = includeMicrophone ? microphoneBuffer.count : 0
    let frames = min(maxFrames, max(availableSystem, availableMicrophone))
    guard frames > 0 else { return nil }

    var samples = [Int16](repeating: 0, count: frames * 2)
    let systemFrames = includeSystem
        ? systemBuffer.drain(into: &samples, channel: 0, maxFrames: frames)
        : 0
    let microphoneFrames = includeMicrophone
        ? microphoneBuffer.drain(into: &samples, channel: 1, maxFrames: frames)
        : 0
    return AlignedPCMChunk(
        samples: samples,
        systemFrames: systemFrames,
        microphoneFrames: microphoneFrames
    )
}

private struct ShutdownAudioDrain {
    var samples: [Int16] = []
    var droppedFrames = 0
    var hadDiscontinuity = false
    var finished = false
}

@discardableResult
private func appendShutdownDrain(
    _ drain: ShutdownAudioDrain,
    fifo: inout PCMSampleFIFO,
    quality: inout AudioQualityAccumulator
) -> Int {
    quality.recordDropped(drain.droppedFrames)
    if drain.hadDiscontinuity {
        fifo.removeAll()
    }
    return fifo.appendPreservingAll(drain.samples)
}

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var systemTapID = AudioObjectID(kAudioObjectUnknown)
    private var systemAggregateID = AudioObjectID(kAudioObjectUnknown)
    private var systemIOProcID: AudioDeviceIOProcID?
    private var systemFormat = AudioStreamBasicDescription()
    private var systemAudioProducer: OpaquePointer?
    private var systemAudioConsumer: OpaquePointer?
    private var microphoneAudioProducer: OpaquePointer?
    private var microphoneAudioConsumer: OpaquePointer?
    private var microphoneDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var microphoneIOProcID: AudioDeviceIOProcID?
    private var microphoneFormat = AudioStreamBasicDescription()
    private var microphoneUID = ""
    private var microphoneMonitor: DispatchSourceTimer?
    private let microphoneLifecycleLock = NSRecursiveLock()
    private var microphoneListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var microphoneRetryAt: TimeInterval = 0
    private var microphoneFailures = 0
    private var microphoneCooldowns: [String: TimeInterval] = [:]
    // HAL may reject unregistering an already-vanished Bluetooth device. Keep
    // its callback context alive until process exit, with a strict upper bound.
    private var retiredMicrophoneRuntimes: [(OpaquePointer?, OpaquePointer?)] = []
    private var microphoneHealth = MicrophoneHealth() // processing queue only
    private var mixTimer: DispatchSourceTimer?
    private var parentMonitor: DispatchSourceTimer?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "app.arco.recorder")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lifecycleQueue = DispatchQueue(label: "app.arco.recorder.lifecycle")
    private let lock = NSLock()
    private var systemBuffer = PCMSampleFIFO(capacity: maxBufferedFrames)
    private var micBuffer = PCMSampleFIFO(capacity: maxBufferedFrames)
    private var processingScratch = [Int16](repeating: 0, count: 8_192)
    private var interleavedOutput = [Int16](repeating: 0, count: frameSize * 2)
    private var systemQuality = AudioQualityAccumulator()
    private var microphoneQuality = AudioQualityAccumulator()
    private var rawMicrophoneQuality = AudioQualityAccumulator()
    private var qualityTick = 0
    private var microphoneAECEnabled = false
    private var echoCanceller: OpaquePointer?
    private var loggedFormats = Set<String>()
    private var systemCaptureStarted = !useSystem
    private var microphoneCaptureStarted = !useMic
    private var announcedReady = false
    private var hasStopped = false
    private let archive = AsyncMeetingAudioArchive(environment: ProcessInfo.processInfo.environment)
    private let output = FileHandle.standardOutput
    private let outputQueue = DispatchQueue(label: "app.arco.recorder.stdout")
    private let outputWriteGate = DispatchSemaphore(value: 1)

    override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start() {
        installTerminationHandlers()
        startParentMonitor()
        configureEchoCancellation()
        startMixTimer()
        if useMic {
            lifecycleQueue.sync {
                startMicrophoneCapture()
                startMicrophoneMonitor()
            }
        }
        if useSystem {
            startSystemCapture()
        }
        announceReadyIfNeeded()
    }

    private func installTerminationHandlers() {
        // Arco stops its owned helper with SIGTERM. Convert that signal into
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

    private func createAudioRuntime(
        format: AudioStreamBasicDescription,
        source: String
    ) -> (producer: OpaquePointer, consumer: OpaquePointer) {
        var format = format
        var producer: OpaquePointer?
        var consumer: OpaquePointer?
        let capacity = UInt32(
            max(4_096, Int(ceil(format.mSampleRate * realtimeBufferDuration)))
        )
        let status = withUnsafePointer(to: &format) { formatPointer in
            arco_audio_rt_source_create(
                formatPointer,
                Double(sampleRate),
                capacity,
                &producer,
                &consumer
            )
        }
        guard status == 0, let producer, let consumer else {
            fail("could not create Rust audio runtime for \(source): \(status)")
        }
        return (producer, consumer)
    }

    @available(macOS 14.2, *)
    private func startCoreAudioTapCapture() {
        log("starting Core Audio system tap")
        let environment = ProcessInfo.processInfo.environment
        var excludedProcesses: [AudioObjectID] = []
        if ParentAudioExclusionPolicy.isRequested(environment: environment) {
            guard let parentPID = ParentAudioExclusionPolicy.parentPID(
                environment: environment
            ) else {
                fail("GPT Live requested parent-audio exclusion without a valid parent PID")
            }
            guard let processObjectID = Self.audioProcessObjectID(for: parentPID) else {
                fail("could not resolve GPT Live playback process for audio exclusion")
            }
            excludedProcesses = [processObjectID]
            log("excluding GPT Live playback process from system audio capture")
        }
        let tapDescription = CATapDescription(
            monoGlobalTapButExcludeProcesses: excludedProcesses
        )
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
        let audioRuntime = createAudioRuntime(format: format, source: "system tap")
        systemAudioProducer = audioRuntime.producer
        systemAudioConsumer = audioRuntime.consumer

        log("registering Core Audio system tap IO callback")
        var ioProcID: AudioDeviceIOProcID?
        let createIOStatus = AudioDeviceCreateIOProcID(
            aggregateID,
            arco_audio_rt_io_proc,
            UnsafeMutableRawPointer(audioRuntime.producer),
            &ioProcID
        )
        guard createIOStatus == noErr, let ioProcID else {
            fail("could not create Core Audio system tap IO callback: \(createIOStatus)")
        }
        systemIOProcID = ioProcID

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            let destroyIOStatus = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            if destroyIOStatus == noErr {
                systemIOProcID = nil
            } else {
                log(
                    "could not unregister Core Audio system tap after start failure: "
                        + "\(destroyIOStatus)"
                )
            }
            fail("could not start Core Audio system tap: \(startStatus)")
        }
        log("system audio capture started with Core Audio tap")
        markSystemCaptureStarted()
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

        let environment = ProcessInfo.processInfo.environment
        var excludedApplications: [SCRunningApplication] = []
        if ParentAudioExclusionPolicy.isRequested(environment: environment) {
            guard let parentPID = ParentAudioExclusionPolicy.parentPID(
                environment: environment
            ) else {
                fail("GPT Live requested parent-audio exclusion without a valid parent PID")
            }
            guard let parentApplication = content.applications.first(where: {
                $0.processID == parentPID
            }) else {
                fail("could not resolve GPT Live playback application for audio exclusion")
            }
            excludedApplications = [parentApplication]
            log("excluding GPT Live playback application from system audio capture")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
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

    private func configureEchoCancellation() {
        let setting = ProcessInfo.processInfo.environment["ARCO_MIC_ECHO_CANCELLATION"]
        guard EchoCancellationPolicy.shouldEnable(mode: mode, setting: setting) else {
            log("microphone echo cancellation bypassed (mode=\(mode))")
            return
        }
        let status = arco_aec_create(&echoCanceller)
        microphoneAECEnabled = status == 0 && echoCanceller != nil
        if microphoneAECEnabled {
            log("microphone software echo cancellation enabled (WebRTC AEC3; playback unchanged)")
        } else {
            log("echo cancellation unavailable; continuing raw: \(status)")
        }
    }

    // Called only from the normal processing queue, or after it has stopped.
    private func applyEchoCancellation(to samples: inout [Int16]) {
        guard let echoCanceller else { return }
        let status = samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Int32(0) }
            return arco_aec_process(echoCanceller, base, UInt32(buffer.count / 2))
        }
        if status != 0 {
            log("echo cancellation failed; continuing raw: \(status)")
            arco_aec_destroy(echoCanceller)
            self.echoCanceller = nil
            microphoneAECEnabled = false
        }
    }

    private func resetEchoCancellation() {
        guard let echoCanceller else { return }
        if arco_aec_reset(echoCanceller) != 0 {
            log("echo cancellation reset failed; continuing raw")
            arco_aec_destroy(echoCanceller)
            self.echoCanceller = nil
            microphoneAECEnabled = false
        }
    }

    private func startMicrophoneCapture() {
        var devices = Self.microphoneCandidates()
        let preferred = preferredMicrophoneUIDs()
        guard chooseMicrophone(preferredUIDs: preferred, devices: devices) != nil else {
            fail("no physical microphone is connected; choose a microphone in macOS")
        }
        while let device = chooseMicrophone(preferredUIDs: preferred, devices: devices) {
            if openMicrophone(device.id, waitForFormat: true) {
                markMicrophoneCaptureStarted()
                return
            }
            microphoneCooldowns[device.uid] = ProcessInfo.processInfo.systemUptime + 30
            devices.removeAll { $0.id == device.id }
        }
        fail("could not start any connected physical microphone")
    }

    /// Control queue only. A failed reopen must not terminate the system stream.
    private func openMicrophone(_ device: AudioDeviceID, waitForFormat: Bool = false) -> Bool {
        guard var format = waitForFormat ? Self.waitForStreamFormat(for: device) : Self.streamFormat(for: device),
              format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { return false }
        var producer: OpaquePointer?
        var consumer: OpaquePointer?
        let status = arco_audio_rt_source_create(&format, Double(sampleRate),
            UInt32(max(4096, Int(ceil(format.mSampleRate * realtimeBufferDuration)))), &producer, &consumer)
        guard status == 0, let producer, let consumer else {
            log("microphone runtime creation failed: \(status)")
            return false
        }
        // Publish before starting callbacks, under the consumer's queue.
        queue.sync {
            microphoneAudioProducer = producer
            microphoneAudioConsumer = consumer
            micBuffer.removeAll()
            microphoneHealth.started(at: ProcessInfo.processInfo.systemUptime)
            resetEchoCancellation()
        }
        microphoneDeviceID = device
        microphoneUID = Self.stringProperty(kAudioDevicePropertyDeviceUID, device: device) ?? ""
        microphoneFormat = format
        var callback: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcID(device, arco_audio_rt_io_proc,
            UnsafeMutableRawPointer(producer), &callback)
        guard created == noErr, let callback else {
            log("microphone callback registration failed: \(created)")
            closeMicrophoneForRecovery()
            return false
        }
        microphoneIOProcID = callback
        let started = AudioDeviceStart(device, callback)
        guard started == noErr else {
            log("microphone start failed: \(started)")
            closeMicrophoneForRecovery()
            return false
        }
        let name = Self.stringProperty(kAudioObjectPropertyName, device: device) ?? microphoneUID
        log("ARCO_MICROPHONE_STATE state=starting device=\(name) sampleRate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame)")
        return true
    }

    private func closeMicrophoneForRecovery() {
        var quiesced = true
        if let callback = microphoneIOProcID {
            _ = AudioDeviceStop(microphoneDeviceID, callback)
            let destroyed = AudioDeviceDestroyIOProcID(microphoneDeviceID, callback)
            quiesced = destroyed == noErr
            microphoneIOProcID = nil
        }
        let handles = queue.sync { () -> (OpaquePointer?, OpaquePointer?) in
            let result = (microphoneAudioProducer, microphoneAudioConsumer)
            microphoneAudioProducer = nil
            microphoneAudioConsumer = nil
            micBuffer.removeAll()
            resetEchoCancellation()
            return result
        }
        if quiesced {
            if let producer = handles.0 { arco_audio_rt_producer_destroy(producer) }
            if let consumer = handles.1 { arco_audio_rt_consumer_destroy(consumer) }
        } else {
            retiredMicrophoneRuntimes.append(handles)
            log("retaining vanished microphone callback context until process exit")
            if retiredMicrophoneRuntimes.count >= 8 {
                fail("microphone recovery could not release repeated device callbacks; restart recording")
            }
        }
        microphoneDeviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    private func startMicrophoneMonitor() {
        // Notifications accelerate hot-plug/default changes; the timer also
        // catches a device that stays enumerated but stops delivering frames.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.checkMicrophoneHealth()
            }
            let object = AudioObjectID(kAudioObjectSystemObject)
            if AudioObjectAddPropertyListenerBlock(object, &address, lifecycleQueue, callback) == noErr {
                microphoneListeners.append((object, address, callback))
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkMicrophoneHealth() }
        microphoneMonitor = timer
        timer.resume()
    }

    private func checkMicrophoneHealth() {
        microphoneLifecycleLock.lock()
        defer { microphoneLifecycleLock.unlock() }
        lock.lock()
        let stopped = hasStopped
        lock.unlock()
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= microphoneRetryAt else { return }
        let health = queue.sync { microphoneHealth }
        let candidates = Self.microphoneCandidates()
        let current = candidates.first { $0.id == microphoneDeviceID && $0.uid == microphoneUID }
        let format = current.flatMap { Self.streamFormat(for: $0.id) }
        let formatChanged = format.map { !sameAudioFormat($0, microphoneFormat) } ?? false
        let action = microphoneRecoveryAction(devices: candidates, preferredUIDs: preferredMicrophoneUIDs(),
            currentID: microphoneDeviceID, currentUID: microphoneUID, hasStream: microphoneIOProcID != nil,
            health: health, formatChanged: formatChanged, cooldowns: &microphoneCooldowns, now: now)
        guard case let .reopen(desired, reason) = action else {
            if health.stable(at: now), microphoneFailures > 0 {
                microphoneFailures = 0
                log("ARCO_MICROPHONE_STATE state=healthy device=\(microphoneUID)")
            }
            return
        }
        log("ARCO_MICROPHONE_STATE state=recovering reason=\(reason)")
        closeMicrophoneForRecovery()
        microphoneFailures += 1
        microphoneRetryAt = now + MicrophoneHealth.retryDelay(failures: microphoneFailures)
        guard let desired else {
            log("ARCO_MICROPHONE_STATE state=unavailable; waiting for a physical microphone")
            return
        }
        if !openMicrophone(desired.id) {
            microphoneCooldowns[desired.uid] = now + 30
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

    func selectMicrophoneDevice() -> AudioDeviceID {
        guard let microphone = chooseMicrophone(preferredUIDs: preferredMicrophoneUIDs(), devices: Self.microphoneCandidates()) else {
            fail("no physical microphone is connected; choose a microphone in macOS")
        }
        let label = Self.stringProperty(kAudioObjectPropertyName, device: microphone.id) ?? microphone.uid
        log("using physical microphone: \(label)")
        return microphone.id
    }

    private func preferredMicrophoneUIDs() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let requestedID = (environment["ARCO_MIC_DEVICE_ID"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let savedRoute = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arco/meeting-audio-route.json")
        let savedUID = (try? Data(contentsOf: savedRoute))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["originalUID"] as? String
        let selectionURL = environment["ARCO_MICROPHONE_SELECTION_FILE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Arco/microphone.json")
        let selectedUID = (try? Data(contentsOf: selectionURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"] as? String
        return [requestedID, selectedUID, AVCaptureDevice.default(for: .audio)?.uniqueID, savedUID].compactMap { $0 }
    }

    private static func microphoneCandidates() -> [MicrophoneCandidate] {
        Self.audioDevices().compactMap { device -> MicrophoneCandidate? in
            guard let uid = Self.stringProperty(kAudioDevicePropertyDeviceUID, device: device),
                  let transport = Self.audioDeviceTransport(device) else { return nil }
            var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var alive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr,
                  alive != 0 else { return nil }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            let hasInput = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
            return MicrophoneCandidate(id: device, uid: uid, transport: transport, hasInput: hasInput)
        }
    }

    private func drainAudioRuntime() {
        if let consumer = systemAudioConsumer {
            let result = drainAudioRuntimeSource(consumer)
            systemQuality.recordDropped(result.droppedFrames)
            if result.discontinuity {
                systemBuffer.removeAll()
                resetEchoCancellation()
            } else if result.count > 0 {
                let dropped = processingScratch.withUnsafeBufferPointer { samples in
                    systemBuffer.append(
                        UnsafeBufferPointer(start: samples.baseAddress, count: result.count)
                    )
                }
                systemQuality.recordDropped(dropped)
            }
        }
        if let consumer = microphoneAudioConsumer {
            let result = drainAudioRuntimeSource(consumer)
            microphoneHealth.received(frames: result.discontinuity ? 0 : result.count,
                at: ProcessInfo.processInfo.systemUptime)
            microphoneQuality.recordDropped(result.droppedFrames)
            if result.discontinuity {
                micBuffer.removeAll()
                resetEchoCancellation()
            } else if result.count > 0 {
                let dropped = processingScratch.withUnsafeBufferPointer { samples in
                    micBuffer.append(
                        UnsafeBufferPointer(start: samples.baseAddress, count: result.count)
                    )
                }
                microphoneQuality.recordDropped(dropped)
            }
        }
    }

    private func drainAudioRuntimeSource(
        _ consumer: OpaquePointer
    ) -> (count: Int, droppedFrames: Int, discontinuity: Bool) {
        let result = processingScratch.withUnsafeMutableBufferPointer { destination in
            arco_audio_rt_consumer_drain_i16(
                consumer,
                destination.baseAddress!,
                UInt32(destination.count)
            )
        }
        guard result.status == 0 else {
            log("Rust audio runtime drain failed: \(result.status)")
            return (0, 0, true)
        }
        return (
            min(processingScratch.count, Int(result.frame_count)),
            Int(clamping: result.dropped_input_frames),
            result.discontinuity != 0
        )
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
        drainAudioRuntime()
        // Drain both FIFO queues on the same 100 ms clock. A late or disabled
        // source is represented by zeroes, never by shifting the other channel
        // in time and never by summing both speakers into one sample.
        for index in interleavedOutput.indices {
            interleavedOutput[index] = 0
        }
        let systemCount = useSystem
            ? systemBuffer.drain(
                into: &interleavedOutput,
                channel: 0,
                maxFrames: frameSize
            )
            : 0
        let micCount = useMic
            ? micBuffer.drain(
                into: &interleavedOutput,
                channel: 1,
                maxFrames: frameSize
            )
            : 0
        let rawPayload = interleavedOutput.withUnsafeBytes { Data($0) }
        if useMic {
            rawMicrophoneQuality.observeInterleaved(samples: interleavedOutput,
                channel: 1, actualFrames: micCount, paddedFrames: frameSize - micCount)
        }
        applyEchoCancellation(to: &interleavedOutput)
        if useSystem {
            systemQuality.observeInterleaved(
                samples: interleavedOutput,
                channel: 0,
                actualFrames: systemCount,
                paddedFrames: frameSize - systemCount
            )
        }
        if useMic {
            microphoneQuality.observeInterleaved(
                samples: interleavedOutput,
                channel: 1,
                actualFrames: micCount,
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

        if let systemSnapshot {
            logQuality(source: "system", snapshot: systemSnapshot, aec: false)
        }
        if let microphoneSnapshot {
            logQuality(source: "microphone_raw", snapshot: rawMicrophoneQuality.takeSnapshot(), aec: false)
            logQuality(
                source: "microphone",
                snapshot: microphoneSnapshot,
                aec: microphoneAECEnabled
            )
        }

        // Emit even during silence so channel alignment remains stable from
        // process start through permission prompts and transient device gaps.
        guard outputWriteGate.wait(timeout: .now()) == .success else {
            lifecycleQueue.async { [weak self] in
                self?.stopAndExit(1, reason: "audio consumer stopped draining; stopping native recorder")
            }
            return
        }
        let payload = interleavedOutput.withUnsafeBytes { Data($0) }
        outputQueue.async { [weak self] in
            guard let self else { return }
            let emitted = payload.withUnsafeBytes { bytes in
                self.writeAll(bytes)
            }
            self.archive?.append(rawPayload)
            self.outputWriteGate.signal()
            guard !emitted else { return }
            self.lifecycleQueue.async { [weak self] in
                self?.stopAndExit(
                    0,
                    reason: "audio consumer closed; stopping native recorder"
                )
            }
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
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let formatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return }
        let format = formatPointer.pointee
        if systemAudioProducer == nil {
            let audioRuntime = createAudioRuntime(format: format, source: "ScreenCaptureKit")
            systemFormat = format
            systemAudioProducer = audioRuntime.producer
            systemAudioConsumer = audioRuntime.consumer
        }
        guard let producer = systemAudioProducer else { return }

        var requiredSize = 0
        var blockBuffer: CMBlockBuffer?
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard sizeStatus == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size else {
            return
        }
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let audioBuffers = rawList.assumingMemoryBound(to: AudioBufferList.self)
        let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBuffers,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard listStatus == noErr else { return }
        _ = arco_audio_rt_push_audio_buffer_list(producer, audioBuffers)
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

    private static func audioDevices() -> [AudioDeviceID] {
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
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func audioDeviceTransport(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    @available(macOS 14.2, *)
    private static func audioProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var requestedPID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &requestedPID) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &outputSize,
                &processObjectID
            )
        }
        guard status == noErr,
              processObjectID != AudioObjectID(kAudioObjectUnknown)
        else { return nil }
        return processObjectID
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

        microphoneLifecycleLock.lock()
        defer { microphoneLifecycleLock.unlock() }
        microphoneMonitor?.cancel()
        microphoneMonitor = nil
        for (object, var address, callback) in microphoneListeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, lifecycleQueue, callback)
        }
        microphoneListeners.removeAll()

        // Stop every real-time producer before releasing its opaque Rust
        // producer handle. The Rust consumer worker is released last so it can
        // finish its bounded tail flush without racing either callback.
        var microphoneCallbacksQuiesced = true
        if let callback = microphoneIOProcID {
            let stopped = AudioDeviceStop(microphoneDeviceID, callback)
            let destroyed = AudioDeviceDestroyIOProcID(microphoneDeviceID, callback)
            microphoneCallbacksQuiesced = stopped == noErr && destroyed == noErr
            microphoneIOProcID = nil
            if !microphoneCallbacksQuiesced {
                log("microphone callback stop incomplete; retaining handles for process exit")
            }
        }

        var systemCallbacksQuiesced = true
        if #available(macOS 14.2, *) {
            systemCallbacksQuiesced = stopCoreAudioTapCapture()
        }

        if let stream {
            let semaphore = DispatchSemaphore(value: 0)
            var stoppedCleanly = false
            stream.stopCapture { error in
                if let error {
                    self.log("could not stop ScreenCaptureKit capture cleanly: \(error)")
                } else {
                    stoppedCleanly = true
                }
                semaphore.signal()
            }
            let waitResult = semaphore.wait(timeout: .now() + 1)
            if waitResult == .timedOut {
                log("ScreenCaptureKit stop timed out; leaving Rust system handles for process exit")
            }
            systemCallbacksQuiesced = waitResult == .success && stoppedCleanly
            self.stream = nil
        }

        mixTimer?.cancel()
        mixTimer = nil
        let processingQueueQuiesced: Bool
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            processingQueueQuiesced = false
            log("audio processing queue is stopping itself; leaving Rust handles for process exit")
        } else {
            queue.sync {}
            processingQueueQuiesced = true
        }
        parentMonitor?.cancel()
        parentMonitor = nil
        for source in terminationSignalSources {
            source.cancel()
        }
        terminationSignalSources.removeAll()

        stopAudioRuntime(
            systemCallbacksQuiesced: systemCallbacksQuiesced && processingQueueQuiesced,
            microphoneCallbacksQuiesced: microphoneCallbacksQuiesced
                && processingQueueQuiesced
        )
        if processingQueueQuiesced, let echoCanceller {
            arco_aec_destroy(echoCanceller)
            self.echoCanceller = nil
        }
        archive?.finish()
    }

    private func stopAudioRuntime(
        systemCallbacksQuiesced: Bool,
        microphoneCallbacksQuiesced: Bool
    ) {
        let systemProducer = systemAudioProducer
        let systemConsumer = systemAudioConsumer
        let microphoneProducer = microphoneAudioProducer
        let microphoneConsumer = microphoneAudioConsumer
        systemAudioProducer = nil
        microphoneAudioProducer = nil
        systemAudioConsumer = nil
        microphoneAudioConsumer = nil

        let ownsOutputGate = outputWriteGate.wait(timeout: .now() + 1) == .success
        if !ownsOutputGate {
            log("could not acquire stdout for the recorder shutdown tail")
        }

        if !systemCallbacksQuiesced {
            log("leaving Rust audio runtime handles for system to process teardown")
        } else if let systemProducer {
            let finishStatus = arco_audio_rt_producer_finish(systemProducer)
            if finishStatus != 0 {
                log("Rust audio runtime could not finish system: \(finishStatus)")
            }
        }
        if !microphoneCallbacksQuiesced {
            log("leaving Rust audio runtime handles for microphone to process teardown")
        } else if let microphoneProducer {
            let finishStatus = arco_audio_rt_producer_finish(microphoneProducer)
            if finishStatus != 0 {
                log("Rust audio runtime could not finish microphone: \(finishStatus)")
            }
        }

        if systemCallbacksQuiesced, let systemConsumer {
            let drain = drainFinishedAudioRuntimeSource(systemConsumer, label: "system")
            let expansion = appendShutdownDrain(
                drain,
                fifo: &systemBuffer,
                quality: &systemQuality
            )
            if expansion > 0 {
                log("shutdown PCM FIFO overflow avoided for system by growing \(expansion) frames")
            }
        }
        if microphoneCallbacksQuiesced, let microphoneConsumer {
            let drain = drainFinishedAudioRuntimeSource(microphoneConsumer, label: "microphone")
            let expansion = appendShutdownDrain(
                drain,
                fifo: &micBuffer,
                quality: &microphoneQuality
            )
            if expansion > 0 {
                log("shutdown PCM FIFO overflow avoided for microphone by growing \(expansion) frames")
            }
        }

        if ownsOutputGate {
            if !emitRemainingPCM() {
                log("recorder shutdown tail output was incomplete")
            }
            outputWriteGate.signal()
        }

        if systemCallbacksQuiesced {
            if let systemProducer {
                arco_audio_rt_producer_destroy(systemProducer)
            }
            if let systemConsumer {
                arco_audio_rt_consumer_destroy(systemConsumer)
            }
        }
        if microphoneCallbacksQuiesced {
            if let microphoneProducer {
                arco_audio_rt_producer_destroy(microphoneProducer)
            }
            if let microphoneConsumer {
                arco_audio_rt_consumer_destroy(microphoneConsumer)
            }
        }
    }

    private func drainFinishedAudioRuntimeSource(
        _ consumer: OpaquePointer,
        label: String
    ) -> ShutdownAudioDrain {
        var drain = ShutdownAudioDrain()
        let deadline = Date().addingTimeInterval(0.25)
        repeat {
            let result = processingScratch.withUnsafeMutableBufferPointer { destination in
                arco_audio_rt_consumer_drain_i16(
                    consumer,
                    destination.baseAddress!,
                    UInt32(destination.count)
                )
            }
            guard result.status == 0 else {
                log("Rust audio runtime drain failed during shutdown for \(label): \(result.status)")
                return drain
            }
            drain.droppedFrames += Int(clamping: result.dropped_input_frames)
            if result.discontinuity != 0 {
                drain.samples.removeAll()
                drain.hadDiscontinuity = true
            } else {
                let count = min(processingScratch.count, Int(result.frame_count))
                if count > 0 {
                    drain.samples.append(contentsOf: processingScratch.prefix(count))
                }
            }
            drain.finished = result.finished != 0
            if result.frame_count == 0, !drain.finished {
                Thread.sleep(forTimeInterval: 0.002)
            }
        } while !drain.finished && Date() < deadline
        if !drain.finished {
            log("Rust audio runtime tail flush timed out for \(label)")
        }
        return drain
    }

    private func emitRemainingPCM() -> Bool {
        while let chunk = drainAlignedPCMChunk(
            systemBuffer: &systemBuffer,
            microphoneBuffer: &micBuffer,
            includeSystem: useSystem,
            includeMicrophone: useMic,
            maxFrames: frameSize
        ) {
            if useSystem {
                systemQuality.observeInterleaved(
                    samples: chunk.samples,
                    channel: 0,
                    actualFrames: chunk.systemFrames,
                    paddedFrames: chunk.samples.count / 2 - chunk.systemFrames
                )
            }
            if useMic {
                microphoneQuality.observeInterleaved(
                    samples: chunk.samples,
                    channel: 1,
                    actualFrames: chunk.microphoneFrames,
                    paddedFrames: chunk.samples.count / 2 - chunk.microphoneFrames
                )
            }
            archive?.append(chunk.samples.withUnsafeBytes { Data($0) })
            var processedSamples = chunk.samples
            applyEchoCancellation(to: &processedSamples)
            let emitted = processedSamples.withUnsafeBytes { bytes in
                writeAll(bytes)
            }
            guard emitted else {
                log("could not write recorder shutdown tail to stdout: errno=\(errno)")
                return false
            }
        }
        return true
    }

    @available(macOS 14.2, *)
    private func stopCoreAudioTapCapture() -> Bool {
        var callbacksQuiesced = true
        let aggregateID = systemAggregateID
        if aggregateID != AudioObjectID(kAudioObjectUnknown),
           let ioProcID = systemIOProcID
        {
            let stopStatus = AudioDeviceStop(aggregateID, ioProcID)
            if stopStatus != noErr {
                log("could not stop Core Audio system tap: \(stopStatus)")
                callbacksQuiesced = false
            }
            let destroyIOStatus = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            if destroyIOStatus != noErr {
                log("could not destroy Core Audio IO callback: \(destroyIOStatus)")
                callbacksQuiesced = false
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
        return callbacksQuiesced
    }

    private func fail(_ message: String) -> Never {
        if let path = ProcessInfo.processInfo.environment["ARCO_RECORDER_ERROR_FILE"], !path.isEmpty {
            try? Data(message.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        log(message)
        stop()
        exit(1)
    }
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

private func exerciseRustAudioRuntime() throws {
    var invalidFormat = AudioStreamBasicDescription()
    var invalidProducer: OpaquePointer?
    var invalidConsumer: OpaquePointer?
    let invalidStatus = withUnsafePointer(to: &invalidFormat) { formatPointer in
        arco_audio_rt_source_create(
            formatPointer,
            Double(sampleRate),
            4_096,
            &invalidProducer,
            &invalidConsumer
        )
    }
    try selfTestRequire(invalidStatus != 0, "invalid linear PCM format was accepted")
    try selfTestRequire(
        invalidProducer == nil && invalidConsumer == nil,
        "failed Rust audio source creation returned live handles"
    )

    var format = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var producer: OpaquePointer?
    var consumer: OpaquePointer?
    let createStatus = withUnsafePointer(to: &format) { formatPointer in
        arco_audio_rt_source_create(
            formatPointer,
            Double(sampleRate),
            96_000,
            &producer,
            &consumer
        )
    }
    try selfTestRequire(createStatus == 0, "Rust audio source creation failed: \(createStatus)")
    guard let producer, let consumer else {
        throw RecorderSelfTestError.failed("Rust audio source returned nil handles")
    }

    let source = sineWave(frequency: 1_000, sampleRate: 48_000, count: 48_000)
    var offset = 0
    for chunkSize in [997, 4_801, 127, 8_113, 16_003, 17_959] {
        let end = min(source.count, offset + chunkSize)
        if end > offset {
            let result = source.withUnsafeBufferPointer { samples in
                var channel = samples.baseAddress!.advanced(by: offset)
                return withUnsafePointer(to: &channel) { channels in
                    arco_audio_rt_push_planar_f32(
                        producer,
                        channels,
                        1,
                        UInt32(end - offset)
                    )
                }
            }
            try selfTestRequire(result.status == 0, "Rust audio push failed: \(result.status)")
            try selfTestRequire(
                Int(result.accepted_frames) == end - offset,
                "Rust audio push dropped self-test input"
            )
            offset = end
        }
    }
    try selfTestRequire(offset == source.count, "self-test did not consume the full input signal")
    try selfTestRequire(arco_audio_rt_producer_finish(producer) == 0, "Rust audio finish failed")
    arco_audio_rt_producer_destroy(producer)

    var converted: [Int16] = []
    var scratch = [Int16](repeating: 0, count: 8_192)
    let deadline = Date().addingTimeInterval(2)
    var finished = false
    repeat {
        let result = scratch.withUnsafeMutableBufferPointer { destination in
            arco_audio_rt_consumer_drain_i16(
                consumer,
                destination.baseAddress!,
                UInt32(destination.count)
            )
        }
        try selfTestRequire(result.status == 0, "Rust audio drain failed: \(result.status)")
        let count = min(scratch.count, Int(result.frame_count))
        converted.append(contentsOf: scratch.prefix(count))
        finished = result.finished != 0
        if count == 0, !finished {
            Thread.sleep(forTimeInterval: 0.002)
        }
    } while !finished && Date() < deadline
    arco_audio_rt_consumer_destroy(consumer)
    try selfTestRequire(finished, "Rust audio runtime did not finish its bounded tail flush")
    try selfTestRequire(
        converted.count == 16_000,
        "48 kHz to 16 kHz produced \(converted.count) frames"
    )
    let outputRMS = sqrt(
        converted.reduce(0.0) { total, sample in
            let normalized = Double(sample) / 32_768.0
            return total + normalized * normalized
        } / Double(converted.count)
    )
    try selfTestRequire(outputRMS > 0.65 && outputRMS < 0.75, "1 kHz tone RMS was \(outputRMS)")
}

private func runRecorderSelfTests() throws {
    try exerciseRustAudioRuntime()
    var health = MicrophoneHealth()
    health.started(at: 100)
    try selfTestRequire(!health.stalled(at: 102.9), "microphone startup grace was lost")
    try selfTestRequire(health.stalled(at: 103), "no callback frames did not trigger recovery")
    health.received(frames: 1600, at: 104) // Includes an entirely silent buffer.
    try selfTestRequire(!health.stalled(at: 106), "valid silence triggered device recovery")
    try selfTestRequire(health.stable(at: 106), "real frames did not establish recovery")
    health.received(frames: 0, at: 107)
    try selfTestRequire(health.stalled(at: 107), "zero padding hid a dead microphone")
    health.started(at: 108)
    try selfTestRequire(!health.stable(at: 114), "opening a device without frames reported healthy")
    try selfTestRequire([1, 2, 3, 99].map { MicrophoneHealth.retryDelay(failures: $0) } == [5, 10, 30, 30], "recovery retry backoff is unbounded")
    var formatA = AudioStreamBasicDescription()
    formatA.mSampleRate = 24000
    formatA.mChannelsPerFrame = 1
    var formatB = formatA
    try selfTestRequire(sameAudioFormat(formatA, formatB), "unchanged format restarted microphone")
    formatB.mSampleRate = 48000
    try selfTestRequire(!sameAudioFormat(formatA, formatB), "Bluetooth sample rate change was missed")
    formatB = formatA
    formatB.mFormatFlags = kAudioFormatFlagIsFloat
    try selfTestRequire(!sameAudioFormat(formatA, formatB), "PCM representation change was missed")
    let physical = MicrophoneCandidate(id: 1, uid: "built-in", transport: kAudioDeviceTransportTypeBuiltIn, hasInput: true)
    let usb = MicrophoneCandidate(id: 2, uid: "usb", transport: kAudioDeviceTransportTypeUSB, hasInput: true)
    let virtual = MicrophoneCandidate(id: 3, uid: "BlackHole2ch_UID", transport: kAudioDeviceTransportTypeVirtual, hasInput: true)
    let output = MicrophoneCandidate(id: 4, uid: "speaker", transport: kAudioDeviceTransportTypeBuiltIn, hasInput: false)
    try selfTestRequire(chooseMicrophone(preferredUIDs: ["gone", virtual.uid], devices: [virtual, output, usb, physical])?.id == physical.id, "virtual default must fall back to built-in microphone")
    try selfTestRequire(chooseMicrophone(preferredUIDs: [usb.uid], devices: [physical, usb])?.id == usb.id, "explicit physical microphone must win")
    try selfTestRequire(chooseMicrophone(preferredUIDs: [virtual.uid, usb.uid], devices: [virtual, usb, physical])?.id == usb.id, "saved physical route must beat generic fallback")
    try selfTestRequire(chooseMicrophone(preferredUIDs: [], devices: [virtual, output]) == nil, "outputs and virtual devices must not qualify as microphones")

    // Exercise a whole unplug/reconnect sequence without touching real devices.
    var cooldowns: [String: TimeInterval] = [:]
    var liveHealth = MicrophoneHealth()
    liveHealth.started(at: 0)
    liveHealth.received(frames: 1600, at: 10)
    func action(_ devices: [MicrophoneCandidate], current: MicrophoneCandidate, now: TimeInterval,
                changed: Bool = false, hasStream: Bool = true) -> MicrophoneRecoveryAction {
        microphoneRecoveryAction(devices: devices, preferredUIDs: [usb.uid, virtual.uid],
            currentID: current.id, currentUID: current.uid, hasStream: hasStream, health: liveHealth,
            formatChanged: changed, cooldowns: &cooldowns, now: now)
    }
    if case .keep = action([usb, physical], current: usb, now: 11) {} else {
        throw RecorderSelfTestError.failed("healthy pinned microphone changed devices")
    }
    if case let .reopen(target, _) = action([virtual, physical], current: usb, now: 11) {
        try selfTestRequire(target?.id == physical.id, "disconnected preferred mic did not fall back to built-in")
    } else { throw RecorderSelfTestError.failed("unplugged microphone was kept") }
    if case let .reopen(target, _) = action([usb, physical], current: physical, now: 11) {
        try selfTestRequire(target?.id == usb.id, "reconnected preferred microphone was not restored")
    } else { throw RecorderSelfTestError.failed("preferred reconnect was missed") }
    if case .keep = action([], current: usb, now: 11) {} else {
        throw RecorderSelfTestError.failed("transient empty enumeration killed a healthy stream")
    }
    if case let .reopen(target, reason) = action([usb, physical], current: usb, now: 14) {
        try selfTestRequire(target?.id == physical.id && reason == "no_frames", "present but stalled device did not fail over")
    } else { throw RecorderSelfTestError.failed("stalled microphone was kept") }
    liveHealth.received(frames: 1600, at: 15)
    if case .keep = action([usb, physical], current: physical, now: 16) {} else {
        throw RecorderSelfTestError.failed("stalled preferred device caused immediate switch-back")
    }
    liveHealth.received(frames: 1600, at: 45)
    if case let .reopen(target, _) = action([usb, physical], current: physical, now: 45) {
        try selfTestRequire(target?.id == usb.id, "cooldown never allowed preferred device to recover")
    } else { throw RecorderSelfTestError.failed("cooldown did not expire") }
    if case let .reopen(target, reason) = action([usb, physical], current: usb, now: 45, changed: true) {
        try selfTestRequire(target?.id == usb.id && reason == "format_changed", "Bluetooth format switch did not rebuild same device")
    } else { throw RecorderSelfTestError.failed("format change ignored") }
    if case let .reopen(target, _) = action([virtual, output], current: usb, now: 45, hasStream: false) {
        try selfTestRequire(target == nil, "unavailable state opened a virtual loopback device")
    } else { throw RecorderSelfTestError.failed("no-device recovery was skipped") }

    try selfTestRequire(
        ParentAudioExclusionPolicy.parentPID(environment: [
            "ARCO_EXCLUDE_PARENT_AUDIO": "1",
            "ARCO_PARENT_PID": "4242",
        ]) == 4_242,
        "explicit GPT Live parent exclusion did not preserve the worker PID"
    )
    try selfTestRequire(
        ParentAudioExclusionPolicy.parentPID(environment: [
            "ARCO_EXCLUDE_PARENT_AUDIO": "0",
            "ARCO_PARENT_PID": "4242",
        ]) == nil,
        "disabled parent-audio exclusion still excluded a process"
    )
    try selfTestRequire(
        ParentAudioExclusionPolicy.parentPID(environment: [
            "ARCO_EXCLUDE_PARENT_AUDIO": "1",
            "ARCO_PARENT_PID": "not-a-pid",
        ]) == nil,
        "invalid parent PID was accepted for audio exclusion"
    )

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

    var pcmFIFO = PCMSampleFIFO(capacity: 4)
    try selfTestRequire(pcmFIFO.append([1, 2, 3]) == 0, "PCM FIFO dropped available space")
    var pcmOutput = [Int16](repeating: 0, count: 4)
    try selfTestRequire(
        pcmFIFO.drain(into: &pcmOutput, channel: 1, maxFrames: 2) == 2,
        "PCM FIFO drained the wrong frame count"
    )
    try selfTestRequire(pcmOutput == [0, 1, 0, 2], "PCM FIFO interleaving changed")
    try selfTestRequire(pcmFIFO.append([4, 5, 6, 7]) == 1, "PCM FIFO overflow count changed")
    var wrappedPCMOutput = [Int16](repeating: 0, count: 8)
    try selfTestRequire(
        pcmFIFO.drain(into: &wrappedPCMOutput, channel: 0, maxFrames: 4) == 4,
        "wrapped PCM FIFO drained the wrong frame count"
    )
    try selfTestRequire(
        wrappedPCMOutput == [4, 0, 5, 0, 6, 0, 7, 0],
        "PCM FIFO did not retain the freshest bounded audio"
    )

    var shutdownSystem = PCMSampleFIFO(capacity: 3)
    var shutdownMicrophone = PCMSampleFIFO(capacity: 2)
    try selfTestRequire(
        shutdownSystem.append([11, 12, 13]) == 0,
        "shutdown system fixture overflowed"
    )
    try selfTestRequire(
        shutdownMicrophone.append([21]) == 0,
        "shutdown microphone fixture overflowed"
    )
    let alignedTail = drainAlignedPCMChunk(
        systemBuffer: &shutdownSystem,
        microphoneBuffer: &shutdownMicrophone,
        includeSystem: true,
        includeMicrophone: true,
        maxFrames: frameSize
    )
    try selfTestRequire(
        alignedTail?.samples == [11, 21, 12, 0, 13, 0],
        "shutdown tail did not preserve stereo alignment and zero padding"
    )
    try selfTestRequire(
        alignedTail?.systemFrames == 3 && alignedTail?.microphoneFrames == 1,
        "shutdown tail reported the wrong per-source frame counts"
    )
    try selfTestRequire(
        drainAlignedPCMChunk(
            systemBuffer: &shutdownSystem,
            microphoneBuffer: &shutdownMicrophone,
            includeSystem: true,
            includeMicrophone: true,
            maxFrames: frameSize
        ) == nil,
        "shutdown tail left PCM behind"
    )

    var disabledSystem = PCMSampleFIFO(capacity: 1)
    var microphoneOnly = PCMSampleFIFO(capacity: 2)
    try selfTestRequire(disabledSystem.append([99]) == 0, "disabled source fixture overflowed")
    try selfTestRequire(microphoneOnly.append([31, 32]) == 0, "mic-only fixture overflowed")
    let microphoneOnlyTail = drainAlignedPCMChunk(
        systemBuffer: &disabledSystem,
        microphoneBuffer: &microphoneOnly,
        includeSystem: false,
        includeMicrophone: true,
        maxFrames: frameSize
    )
    try selfTestRequire(
        microphoneOnlyTail?.samples == [0, 31, 0, 32],
        "mic-only shutdown tail did not keep system audio silent"
    )

    var shutdownOverflow = PCMSampleFIFO(capacity: 2)
    try selfTestRequire(
        shutdownOverflow.append([1, 2]) == 0,
        "shutdown overflow fixture did not fill its FIFO"
    )
    try selfTestRequire(
        shutdownOverflow.appendPreservingAll([3, 4, 5]) > 0,
        "shutdown FIFO did not expand to preserve a resampler tail"
    )
    var preservedOutput = [Int16](repeating: 0, count: 10)
    try selfTestRequire(
        shutdownOverflow.drain(into: &preservedOutput, channel: 0, maxFrames: 5) == 5,
        "expanded shutdown FIFO lost frames"
    )
    try selfTestRequire(
        preservedOutput == [1, 0, 2, 0, 3, 0, 4, 0, 5, 0],
        "expanded shutdown FIFO changed frame order"
    )

    try selfTestRequire(EchoCancellationPolicy.shouldEnable(mode: "both", setting: nil), "mixed capture must cancel speaker playback echo by default")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "mic", setting: nil), "mic-only mode enabled AEC")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "both", setting: "off"), "explicit AEC off was ignored")
    try selfTestRequire(EchoCancellationPolicy.shouldEnable(mode: "both", setting: "on"), "explicit AEC on was ignored")
    try selfTestRequire(EchoCancellationPolicy.shouldEnable(mode: "both", setting: " ON "), "normalized AEC opt-in was ignored")
    try selfTestRequire(EchoCancellationPolicy.shouldEnable(mode: "both", setting: ""), "empty AEC setting must use the mixed capture default")
    try selfTestRequire(EchoCancellationPolicy.shouldEnable(mode: "both", setting: "unexpected"), "unknown AEC setting must use the mixed capture default")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "both", setting: " OFF "), "normalized explicit AEC off was ignored")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "system", setting: "on"), "system-only capture must not enable microphone AEC")
    try selfTestRequire(!EchoCancellationPolicy.shouldEnable(mode: "mic", setting: "on"), "microphone-only capture must not enable playback-reference AEC")

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
} else if mode == "--check-microphone" {
    let recorder = Recorder()
    let selected = recorder.selectMicrophoneDevice()
    print("ARCO_MICROPHONE_CHECK_OK device=\(selected)")
} else {
    let recorder = Recorder()
    recorder.start()
    RunLoop.main.run()
}
