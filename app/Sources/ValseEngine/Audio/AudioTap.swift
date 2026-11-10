@preconcurrency import AVFoundation
import MediaToolbox
import Foundation

/// Block-processing callback of one audio lane: an MTAudioProcessingTap on an export / mixdown reader's audio-mix lane
/// (`AudioTap.make`), or called directly by `PreviewAudioLanes` on the preview reader's buffers (no tap in preview).
/// No locks that can block for long, no allocation in steady state.
/// `buffers` are non-interleaved Float32 channels, `time` is the composition time of the first frame and `duration` the
/// composition time the buffer covers (`frames / sampleRate`) — except on speed-scaled segments in a tap, where
/// `duration` is that span × speed² (see `LaneProcessor.step`, which measures the span from consecutive timestamps);
/// either may be invalid. AVAssetReaderAudioMixOutput stamps exactly on every OS. AVPlayer's post-effects tap stamps
/// do NOT (macOS 26 subtracts the time-pitch latency twice, macOS 13 is exact: docs/investigations/BUG-METALLIC-AUDIO.md
/// part 5), which is why preview audio no longer goes through AVPlayer and taps (`PreviewAudio`).
public protocol AudioTapProcessor: AnyObject, Sendable {
    func prepare(sampleRate: Double, channels: Int, maxFrames: Int)
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, time: CMTime, duration: CMTime)
    func reset()
}

/// Wraps an `AudioTapProcessor` in an MTAudioProcessingTap (works for AVPlayer playback AND
/// AVAssetReaderAudioMixOutput, so preview and export run the exact same DSP).
enum AudioTap {
    final class Box { let processor: AudioTapProcessor; var nonFloat = false, warned = false; init(_ p: AudioTapProcessor) { processor = p } }

    static func make(_ processor: AudioTapProcessor) -> MTAudioProcessingTap? {
        let box = Unmanaged.passRetained(Box(processor)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: box,
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                let box = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                box.nonFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0 || asbd.mBitsPerChannel != 32
                box.processor.prepare(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), maxFrames: Int(maxFrames))
            },
            unprepare: { tap in
                Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().processor.reset()
            },
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                var range = CMTimeRange()
                let st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, &range, numberFramesOut)
                guard st == noErr else { return }
                let box = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard !box.nonFloat else {
                    if !box.warned { box.warned = true; EngineLog.error("audio tap got non-Float32 audio: lane processing and clip volumes skipped") }
                    return
                }
                box.processor.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(numberFramesOut.pointee),
                                      time: range.start, duration: range.duration)
            })
        var tap: MTAudioProcessingTap?
        // BUG-CUT-AUDIO-HOLE investigation: `VALSE_TAP_PRE=1` (tests / probes only) installs the lane taps pre-effects
        // (`TapProbeTests`, docs/investigations/BUG-METALLIC-AUDIO.md). Shipping behaviour: post-effects.
        let flag = ProcessInfo.processInfo.environment["VALSE_TAP_PRE"] != nil ? kMTAudioProcessingTapCreationFlag_PreEffects : kMTAudioProcessingTapCreationFlag_PostEffects
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, flag, &tap)
        if err != noErr { Unmanaged<Box>.fromOpaque(box).release(); return nil }
        return tap
    }
}
