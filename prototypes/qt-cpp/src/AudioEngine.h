#pragma once
// Real-time audio: miniaudio (CoreAudio) device callback + Rubber Band time-stretch (pitch preserved).
// Threads: a feeder thread runs the stretcher and fills a lock-free SPSC ring; the CoreAudio callback
// only copies from the ring (no locks, no allocation). The playback position derived from the samples
// actually consumed by the device is the master clock for video.
#include <string>
#include <vector>
#include <atomic>
#include <thread>
#include <memory>

class AudioEngine {
public:
    AudioEngine();
    ~AudioEngine();
    bool load(const std::string &mediaPath);     // decodes the audio track (FFmpeg + swresample) to float stereo
    bool start(double rate);                      // starts device + stretcher at the given speed
    void stop();
    double mediaSeconds() const;                  // media time of what was played (rate-aware)

    // verification
    double measuredRatio() const;                 // input consumed / output produced (should == rate)
    double inputPitchHz() const { return m_inPitch; }
    double outputPitchHz() const;                 // estimated from the produced output
    long underruns() const { return m_underruns.load(); }
    static const char *backendName();

    // called from the device callback
    void render(float *out, unsigned frames);

private:
    void feeder();
    static double estimatePitch(const float *stereo, size_t frames, int sr);

    int m_sr = 48000;
    std::vector<float> m_pcm;            // interleaved stereo input
    double m_rate = 1.0, m_inPitch = 0;
    struct Impl; std::unique_ptr<Impl> d;
    std::thread m_feeder;
    std::atomic<bool> m_run{false};
    std::atomic<long> m_inputConsumed{0}, m_outputProduced{0}, m_played{0}, m_underruns{0};
    std::vector<float> m_tap;            // copy of produced output (feeder side) for pitch check
};
