@preconcurrency import AVFoundation
import MediaToolbox
import Foundation

/// Block-processing callback installed on one audio-mix lane. Called on the audio render thread (real-time in
/// preview): no locks that can block for long, no allocation in steady state.
/// `buffers` are non-interleaved Float32 channels, `time` is the composition time of the first frame and `duration` the
/// composition time the buffer covers (`frames / sampleRate` × the playback rate: the tap runs after the time-pitch
/// stage) — except on speed-scaled segments, where `duration` is that span × speed² (both paths: see
/// `LaneProcessor.step`, which measures the span from consecutive timestamps); either may be invalid. In AVPlayer playback `time` is one buffer EARLY (the start of the previous pull:
/// the samples are those of `time + duration`); in AVAssetReaderAudioMixOutput (export) it is exact. See
/// `LaneProcessor.labelsLeadOneBuffer` and docs/investigations/BUG-METALLIC-AUDIO.md. (A pre-effects tap is labelled
/// exactly in both, but its `duration` is wrong on speed-scaled segments: 1.5× the frames' span at speed 1.5, the
/// labels advancing 1/1.5×.)
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
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if err != noErr { Unmanaged<Box>.fromOpaque(box).release(); return nil }
        return tap
    }
}
