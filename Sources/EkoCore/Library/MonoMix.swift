import AVFoundation
import MediaToolbox

/// Recordings from Eko 0.1.2 on keep You on the left channel and Others on the right. Played as they are, each
/// side is in one ear only. This audio mix averages the two channels, so both sides are heard in both ears;
/// the file is not changed. Used by the Library's player (and testable with `AVAssetReaderAudioMixOutput`).
public enum MonoMix {
    public static func audioMix(for track: AVAssetTrack) -> AVAudioMix? {
        // Per-tap state: whether the processing format is 32-bit float (anything else is passed through untouched).
        let isFloat = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        isFloat.initialize(to: false)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(isFloat),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                let p = MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: Bool.self)
                p.deinitialize(count: 1)
                p.deallocate()
            },
            prepare: { tap, _, format in
                let f = format.pointee
                MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: Bool.self).pointee =
                    f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr,
                      MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: Bool.self).pointee else { return }
                MonoMix.average(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            })
        var created: Unmanaged<MTAudioProcessingTap>?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &created) == noErr,
              let tap = created?.takeRetainedValue() else {
            isFloat.deinitialize(count: 1)
            isFloat.deallocate()
            return nil
        }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }

    /// Averages left and right in place: two non-interleaved float buffers, or one interleaved stereo buffer.
    static func average(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        if buffers.count == 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            let n = min(frames, Int(buffers[0].mDataByteSize) / 4, Int(buffers[1].mDataByteSize) / 4)
            for i in 0..<n {
                let m = (l[i] + r[i]) * 0.5
                l[i] = m
                r[i] = m
            }
        } else if buffers.count == 1, buffers[0].mNumberChannels == 2, let p = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let n = min(frames, Int(buffers[0].mDataByteSize) / 8)
            for i in 0..<n {
                let m = (p[2 * i] + p[2 * i + 1]) * 0.5
                p[2 * i] = m
                p[2 * i + 1] = m
            }
        }
    }
}
