// Meeting recorder: ScreenCaptureKit captures system audio (the remote side),
// AVAudioEngine captures the microphone, and the recorder mixes them into
// 16kHz / 16-bit / mono PCM for listen.py (Deepgram ASR).
// Usage: recorder [both|system|mic]   (default both)
// Requires Screen Recording + Microphone permission.

import AVFoundation
import AudioToolbox
import CoreAudio
import ScreenCaptureKit
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "both"
let useSystem = (mode == "both" || mode == "system")
let useMic = (mode == "both" || mode == "mic")

let SAMPLE_RATE = 16000
let FRAME = 1600 // 100ms @ 16k

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    var stream: SCStream?
    var micEngine: AVAudioEngine?
    var mixTimer: DispatchSourceTimer?
    let q = DispatchQueue(label: "arco.rec")
    let lock = NSLock()
    var systemBuf: [Int16] = []
    var micBuf: [Int16] = []
    var loggedFormats = Set<String>()
    let stdout = FileHandle.standardOutput

    func start() {
        startMixTimer(queue: q)
        if useMic {
            startMicCapture(queue: q)
        }
        guard useSystem else {
            FileHandle.standardError.write("recorder started (mode=\(mode))\n".data(using: .utf8)!)
            return
        }
        startSystemCapture(queue: q)
    }

    func startSystemCapture(queue: DispatchQueue) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
            guard let display = content?.displays.first else {
                FileHandle.standardError.write("no available display (Screen Recording permission?)\n".data(using: .utf8)!)
                exit(1)
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = SAMPLE_RATE
            cfg.channelCount = 1
            cfg.excludesCurrentProcessAudio = true
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.showsCursor = false
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            self.stream = stream
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                // A screen output is required, otherwise the stream won't start audio.
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            } catch {
                FileHandle.standardError.write("addStreamOutput failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
            stream.startCapture { e in
                if let e = e {
                    FileHandle.standardError.write("startCapture failed: \(e)\n".data(using: .utf8)!)
                    exit(1)
                }
                FileHandle.standardError.write("recorder started (mode=\(mode))\n".data(using: .utf8)!)
            }
        }
    }

    func startMicCapture(queue: DispatchQueue) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        configureMicDevice(input: input)
        let format = input.outputFormat(forBus: 0)
        let channels = max(1, Int(format.channelCount))
        FileHandle.standardError.write("mic engine format sampleRate=\(format.sampleRate) channels=\(channels)\n".data(using: .utf8)!)
        input.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, _ in
            guard let self = self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            for ch in 0..<channels {
                let samples = channelData[ch]
                for frame in 0..<frames {
                    mono[frame] += samples[frame]
                }
            }
            if channels > 1 {
                for frame in 0..<frames {
                    mono[frame] /= Float(channels)
                }
            }
            let pcm = Self.floatToInt16(Self.resample(mono, from: format.sampleRate))
            self.lock.lock()
            self.micBuf.append(contentsOf: pcm)
            self.lock.unlock()
        }
        do {
            engine.prepare()
            try engine.start()
            micEngine = engine
            FileHandle.standardError.write("mic engine started\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("mic engine failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    func configureMicDevice(input: AVAudioInputNode) {
        let env = ProcessInfo.processInfo.environment
        let requestedID = (env["ARCO_MIC_DEVICE_ID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = (env["ARCO_MIC_DEVICE_NAME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if requestedID.isEmpty {
            if let mic = AVCaptureDevice.default(for: .audio) {
                FileHandle.standardError.write("using system default microphone: \(mic.localizedName) id=\(mic.uniqueID)\n".data(using: .utf8)!)
            } else {
                FileHandle.standardError.write("using system default microphone: no AVCaptureDevice default found\n".data(using: .utf8)!)
            }
            return
        }

        guard var deviceID = Self.audioDeviceID(forUID: requestedID) else {
            FileHandle.standardError.write("requested microphone not found: \(requestedName) id=\(requestedID); using system default input\n".data(using: .utf8)!)
            return
        }
        guard let audioUnit = input.audioUnit else {
            FileHandle.standardError.write("input audio unit unavailable; using system default input\n".data(using: .utf8)!)
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
            let label = requestedName.isEmpty ? requestedID : "\(requestedName) id=\(requestedID)"
            FileHandle.standardError.write("using configured microphone: \(label)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("failed to set microphone id=\(requestedID) status=\(status); using system default input\n".data(using: .utf8)!)
        }
    }

    func startMixTimer(queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.mixAndEmit() }
        timer.resume()
        mixTimer = timer
    }

    func mixAndEmit() {
        lock.lock()
        var out = [Int16](repeating: 0, count: FRAME)
        var has = false
        if systemBuf.count >= FRAME {
            for i in 0..<FRAME { out[i] = systemBuf[i] }
            systemBuf.removeFirst(FRAME)
            has = true
        }
        if micBuf.count >= FRAME {
            for i in 0..<FRAME {
                let s = Int32(out[i]) + Int32(micBuf[i])
                out[i] = Int16(max(-32768, min(32767, s)))
            }
            micBuf.removeFirst(FRAME)
            has = true
        }
        lock.unlock()
        if has {
            out.withUnsafeBytes { stdout.write(Data($0)) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, sampleBuffer.isValid else { return }
        logAudioFormatOnce(sampleBuffer, source: type == .audio ? "system" : "mic")
        guard let pcm = Self.extractInt16(sampleBuffer) else { return }
        lock.lock()
        if type == .audio { systemBuf.append(contentsOf: pcm) }
        else { micBuf.append(contentsOf: pcm) }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("stream stopped: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    func logAudioFormatOnce(_ sb: CMSampleBuffer, source: String) {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return
        }
        let key = "\(source)-\(asbd.mSampleRate)-\(asbd.mChannelsPerFrame)-\(asbd.mFormatID)-\(asbd.mFormatFlags)-\(asbd.mBitsPerChannel)"
        guard !loggedFormats.contains(key) else { return }
        loggedFormats.insert(key)
        let msg = "audio format source=\(source) sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) formatID=\(asbd.mFormatID) flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel)\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
    }

    static func extractInt16(_ sb: CMSampleBuffer) -> [Int16]? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return nil
        }
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let buf = buffers.first, let data = buf.mData else { return nil }
        let flags = asbd.mFormatFlags
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
        let bits = Int(asbd.mBitsPerChannel)
        var mono: [Float] = []

        if isFloat && bits == 32 {
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
            let floats = data.bindMemory(to: Float32.self, capacity: count)
            let frames = count / channels
            mono.reserveCapacity(frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += floats[frame * channels + ch]
                }
                mono.append(sum / Float(channels))
            }
        } else if isSignedInteger && bits == 16 {
            let count = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
            let ints = data.bindMemory(to: Int16.self, capacity: count)
            let frames = count / channels
            mono.reserveCapacity(frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += Float(ints[frame * channels + ch]) / 32768.0
                }
                mono.append(sum / Float(channels))
            }
        } else {
            return nil
        }

        return floatToInt16(resample(mono, from: asbd.mSampleRate))
    }

    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }
        return devices.first { device in
            stringProperty(kAudioDevicePropertyDeviceUID, device: device) == uid
        }
    }

    static func stringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return nil
        }
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (value as String) : nil
    }

    static func floatToInt16(_ samples: [Float]) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = max(-1.0, min(1.0, samples[i]))
            out[i] = Int16(v < 0 ? v * 32768.0 : v * 32767.0)
        }
        return out
    }

    static func resample(_ samples: [Float], from sourceRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sourceRate > 0, abs(sourceRate - Double(SAMPLE_RATE)) > 1 else {
            return samples
        }
        let ratio = Double(SAMPLE_RATE) / sourceRate
        let outCount = max(1, Int(Double(samples.count) * ratio))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) / ratio
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            if idx + 1 < samples.count {
                out[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
            } else {
                out[i] = samples[samples.count - 1]
            }
        }
        return out
    }
}

let rec = Recorder()
rec.start()
RunLoop.main.run()
