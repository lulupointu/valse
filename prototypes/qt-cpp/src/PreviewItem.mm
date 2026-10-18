#include "PreviewItem.h"
#include "Engine.h"
#include "Metrics.h"
#include <rhi/qrhi.h>
#include <cstdio>

Engine *PreviewItem::s_engine = nullptr;
PreviewStats PreviewItem::s_stats;

namespace {
class PreviewRenderer : public QQuickRhiItemRenderer {
public:
    void initialize(QRhiCommandBuffer *) override
    {
        if (m_inited) return;
        Engine *e = PreviewItem::s_engine;
        m_inited = m_comp.init(rhi(), renderTarget()->renderPassDescriptor(), e ? e->layerCount() : 1);
    }
    void synchronize(QQuickRhiItem *) override
    {
        Engine *e = PreviewItem::s_engine;
        if (!e) return;
        m_target = e->targetIndex();
        m_gen = e->seekGeneration();
        m_playing = e->playing();
    }
    void render(QRhiCommandBuffer *cb) override
    {
        Engine *e = PreviewItem::s_engine;
        auto &st = PreviewItem::s_stats;
        if (!e || !m_inited) return;
        if (m_target == m_lastIdx && m_gen == m_lastGen) return; // composition unchanged
        if (!e->framesFor(m_target, m_frames)) {
            static const bool dbg = qEnvironmentVariableIsSet("MONTAGE_DEBUG");
            if (dbg) {
                std::fprintf(stderr, "[%.1f] target %lld not ready:", metrics::nowMs(), (long long)m_target);
                for (size_t i = 0; i < m_frames.size(); ++i) std::fprintf(stderr, " %d", m_frames[i] ? 1 : 0);
                std::fprintf(stderr, "\n");
            }
            if (!st.renderedAny) { // nothing yet: just clear
                cb->beginPass(renderTarget(), QColor(0, 0, 0), {1.0f, 0});
                cb->endPass();
            }
            return; // not decoded yet: keep showing the previous composition (counted as drop later)
        }
        const double t0 = metrics::nowMs();
        m_comp.render(cb, renderTarget(), m_frames, e->layout(renderTarget()->pixelSize()));
        st.renderMsSum = st.renderMsSum + (metrics::nowMs() - t0);
        st.renderCount++;
        if (m_playing && m_gen == m_lastGen) {
            const int64_t last = st.lastIdx.load();
            if (last >= 0 && m_target > last) st.dropped += m_target - last - 1;
            if (last < 0 || m_target > last) st.presented++;
        }
        st.lastIdx = m_target;
        m_lastIdx = m_target; m_lastGen = m_gen;
        st.renderedGen = m_gen;
        st.renderedAny = true;
        m_frames.clear(); // compositor keeps its own references until the GPU is done
    }
private:
    Compositor m_comp;
    bool m_inited = false;
    int64_t m_target = 0, m_lastIdx = -1;
    uint64_t m_gen = 0, m_lastGen = ~0ull;
    bool m_playing = false;
    std::vector<FramePtr> m_frames;
};
}

PreviewItem::PreviewItem(QQuickItem *parent) : QQuickRhiItem(parent) {}

QQuickRhiItemRenderer *PreviewItem::createRenderer() { return new PreviewRenderer; }
