import AVFoundation
import MediaToolbox

/// Archive channels identify sources, not speaker positions. Center them only
/// during playback, retaining the original recording and its separate sources.
@_spi(Testing) public enum RecordingAudioMix {
    public static func make(for track: AVAssetTrack) throws -> AVAudioMix {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: nil,
            init: initializeRecordingTap, finalize: finalizeRecordingTap,
            prepare: prepareRecordingTap, unprepare: nil, process: processRecordingTap)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }

    fileprivate static func center(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int,
                              format: AudioStreamBasicDescription) {
        guard frames > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mChannelsPerFrame == 2,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            if format.mBitsPerChannel == 32 {
                mix(buffers, frames: frames, planar: planar, read: { Double($0 as Float) }, write: { Float($0) })
            } else if format.mBitsPerChannel == 64 {
                mix(buffers, frames: frames, planar: planar, read: { $0 as Double }, write: { $0 })
            }
        } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            if format.mBitsPerChannel == 16 {
                mix(buffers, frames: frames, planar: planar, read: { Double($0 as Int16) }, write: { Int16($0) })
            } else if format.mBitsPerChannel == 32 {
                mix(buffers, frames: frames, planar: planar, read: { Double($0 as Int32) }, write: { Int32($0) })
            }
        }
    }

    private static func mix<T>(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int,
                               planar: Bool, read: (T) -> Double, write: (Double) -> T) {
        let stride = planar ? 1 : 2
        guard buffers.count == (planar ? 2 : 1),
              Int(buffers[0].mDataByteSize) >= frames * stride * MemoryLayout<T>.size,
              let first = buffers[0].mData else { return }
        let left = first.assumingMemoryBound(to: T.self)
        let right: UnsafeMutablePointer<T>
        if planar {
            guard Int(buffers[1].mDataByteSize) >= frames * MemoryLayout<T>.size,
                  let second = buffers[1].mData else { return }
            right = second.assumingMemoryBound(to: T.self)
        } else { right = left.advanced(by: 1) }
        for frame in 0..<frames {
            let i = frame * stride
            // Half of each source keeps simultaneous full-scale speech bounded.
            let mono = write(read(left[i]) * 0.5 + read(right[i]) * 0.5)
            left[i] = mono
            right[i] = mono
        }
    }
}

private func initializeRecordingTap(_ tap: MTAudioProcessingTap, _ client: UnsafeMutableRawPointer?,
                                    _ storage: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    let format = UnsafeMutablePointer<AudioStreamBasicDescription>.allocate(capacity: 1)
    format.initialize(to: AudioStreamBasicDescription())
    storage.pointee = UnsafeMutableRawPointer(format)
}

private func finalizeRecordingTap(_ tap: MTAudioProcessingTap) {
    let format = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: AudioStreamBasicDescription.self)
    format.deinitialize(count: 1)
    format.deallocate()
}

private func prepareRecordingTap(_ tap: MTAudioProcessingTap, _ frames: CMItemCount,
                                 _ format: UnsafePointer<AudioStreamBasicDescription>) {
    MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee = format.pointee
}

private func processRecordingTap(_ tap: MTAudioProcessingTap, _ requested: CMItemCount,
                                 _ inputFlags: MTAudioProcessingTapFlags,
                                 _ buffers: UnsafeMutablePointer<AudioBufferList>,
                                 _ frames: UnsafeMutablePointer<CMItemCount>,
                                 _ flags: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    frames.pointee = 0
    guard MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, frames) == noErr else { return }
    let format = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee
    RecordingAudioMix.center(buffers, frames: frames.pointee, format: format)
}
