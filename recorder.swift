// Meeting recorder: ScreenCaptureKit captures system audio (the remote side) + microphone (you),
// mixes them into 16kHz / 16-bit / mono PCM and writes it to stdout for listen.py (Deepgram ASR).
// Usage: recorder [both|system|mic]   (default both)
// Requires Screen Recording + Microphone permission.

import AVFoundation
import ScreenCaptureKit
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "both"
let useSystem = (mode == "both" || mode == "system")
let useMic = (mode == "both" || mode == "mic")

let SAMPLE_RATE = 16000
let FRAME = 1600 // 100ms @ 16k

final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    var stream: SCStream?
    let lock = NSLock()
    var systemBuf: [Int16] = []
    var micBuf: [Int16] = []
    let stdout = FileHandle.standardOutput

    func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
            guard let display = content?.displays.first else {
                FileHandle.standardError.write("no available display (Screen Recording permission?)\n".data(using: .utf8)!)
                exit(1)
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = useSystem
            cfg.sampleRate = SAMPLE_RATE
            cfg.channelCount = 1
            cfg.excludesCurrentProcessAudio = true
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.showsCursor = false
            if useMic {
                cfg.captureMicrophone = true
            }
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            self.stream = stream
            let q = DispatchQueue(label: "arco.rec")
            do {
                if useSystem {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
                }
                if useMic {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q)
                }
                // A screen output is required, otherwise the stream won't start audio.
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
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
            self.startMixTimer(queue: q)
        }
    }

    func startMixTimer(queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.mixAndEmit() }
        timer.resume()
        // retain the timer
        objc_setAssociatedObject(self, "timer", timer, .OBJC_ASSOCIATION_RETAIN)
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

    static func extractInt16(_ sb: CMSampleBuffer) -> [Int16]? {
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let buf = buffers.first, let data = buf.mData else { return nil }
        let count = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
        let floats = data.bindMemory(to: Float32.self, capacity: count)
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let v = max(-1.0, min(1.0, floats[i]))
            out[i] = Int16(v < 0 ? v * 32768.0 : v * 32767.0)
        }
        return out
    }
}

let rec = Recorder()
rec.start()
RunLoop.main.run()
