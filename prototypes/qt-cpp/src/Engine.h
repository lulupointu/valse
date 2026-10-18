#pragma once
// Playback engine: owns the per-clip decoders, the master clock and the layer layout.
// Thread-safety: frame selection (framesFor) is called on the Qt Quick render thread,
// transport control (play/seek) from the GUI thread.
#include <vector>
#include <memory>
#include <atomic>
#include <mutex>
#include <functional>
#include "ClipDecoder.h"
#include "Compositor.h"

class Engine {
public:
    explicit Engine(std::vector<std::string> paths, int queueCap = 4);
    bool open();
    void start();
    void stop();

    int layerCount() const { return int(m_dec.size()); }
    double fps() const { return m_fps; }
    std::vector<LayerParams> layout(QSize out) const;   // the benchmark composition

    // master clock
    void setClockSource(std::function<double()> mediaSeconds) { m_extClock = std::move(mediaSeconds); }
    void play(double rate = 1.0);
    void pause();
    bool playing() const { return m_playing.load(); }
    int64_t targetIndex() const;   // frame index the display should show now

    // scrub
    void seek(int64_t index);
    uint64_t seekGeneration() const { return m_seekGen.load(); }

    // Returns true and fills `out` when every layer has frame `index` ready.
    bool framesFor(int64_t index, std::vector<FramePtr> &out, bool allowLater = false);
    bool allReady(int64_t index);

    ClipDecoder *decoder(int i) { return m_dec[i].get(); }

private:
    std::vector<std::unique_ptr<ClipDecoder>> m_dec;
    double m_fps = 30;
    std::atomic<bool> m_playing{false};
    double m_rate = 1.0;
    double m_t0Ms = 0;
    int64_t m_baseIndex = 0;
    std::atomic<int64_t> m_pausedIndex{0};
    std::atomic<uint64_t> m_seekGen{0};
    std::function<double()> m_extClock;
    mutable std::mutex m_mx;
};
