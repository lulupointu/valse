#include "Engine.h"
#include "Metrics.h"
#include <cmath>

Engine::Engine(std::vector<std::string> paths, int queueCap)
{
    for (auto &p : paths) m_dec.push_back(std::make_unique<ClipDecoder>(p, queueCap));
}

bool Engine::open()
{
    for (auto &d : m_dec)
        if (!d->open()) { std::fprintf(stderr, "Engine: %s\n", d->lastError().c_str()); return false; }
    m_fps = m_dec.empty() ? 30 : m_dec[0]->fps();
    return true;
}

void Engine::start() { for (auto &d : m_dec) d->start(); }
void Engine::stop() { for (auto &d : m_dec) d->stop(); }

std::vector<LayerParams> Engine::layout(QSize out) const
{
    // 4 layers, each with its own scale/position, opacity 0.8 and a saturation+brightness filter.
    const double W = out.width(), H = out.height();
    std::vector<LayerParams> L;
    const QRectF rects[] = {
        {0, 0, W, H},                                   // background, full frame
        {W * 0.05, H * 0.05, W * 0.55, H * 0.55},      // top-left, scale 0.55
        {W * 0.42, H * 0.10, W * 0.50, H * 0.50},      // top-right, scale 0.5
        {W * 0.25, H * 0.45, W * 0.50, H * 0.50},      // bottom-center, scale 0.5
        // [bench harness] layers 5-8 for the 8-layer stress test (same clips again, smaller, offset)
        {W * 0.05, H * 0.10, W * 0.36, H * 0.36},
        {W * 0.60, H * 0.10, W * 0.33, H * 0.33},
        {W * 0.05, H * 0.55, W * 0.30, H * 0.30},
        {W * 0.60, H * 0.55, W * 0.30, H * 0.30},
    };
    const float sat[] = {0.6f, 1.4f, 0.0f, 1.2f};
    const float bri[] = {-0.05f, 0.05f, 0.1f, 0.0f};
    for (int i = 0; i < layerCount(); ++i) {
        LayerParams p;
        p.rect = rects[i % 8];
        p.opacity = 0.8f;
        p.saturation = sat[i % 4];
        p.brightness = bri[i % 4];
        L.push_back(p);
    }
    return L;
}

void Engine::play(double rate)
{
    std::lock_guard l(m_mx);
    m_rate = rate;
    m_baseIndex = m_pausedIndex.load();
    m_t0Ms = metrics::nowMs();
    m_playing = true;
}

void Engine::pause()
{
    int64_t idx = targetIndex();
    std::lock_guard l(m_mx);
    m_pausedIndex = idx;
    m_playing = false;
}

int64_t Engine::targetIndex() const
{
    if (!m_playing) return m_pausedIndex.load();
    if (m_extClock) return int64_t(std::floor(m_extClock() * m_fps));
    std::lock_guard l(m_mx);
    double s = (metrics::nowMs() - m_t0Ms) / 1000.0 * m_rate;
    return m_baseIndex + int64_t(std::floor(s * m_fps + 1e-6));
}

void Engine::seek(int64_t index)
{
    m_pausedIndex = index;
    for (auto &d : m_dec) d->seek(index);
    m_seekGen++;
}

bool Engine::allReady(int64_t index)
{
    for (auto &d : m_dec) if (!d->acquire(index)) return false;
    return true;
}

bool Engine::framesFor(int64_t index, std::vector<FramePtr> &out, bool allowLater)
{
    out.resize(m_dec.size());
    bool all = true;
    for (size_t i = 0; i < m_dec.size(); ++i) {
        out[i] = m_dec[i]->acquire(index, allowLater);
        if (!out[i]) all = false;
    }
    return all;
}
