#pragma once
// GPU compositor shared by the preview (QQuickRhiItem) and the exporter (offscreen QRhi).
// Inputs: VideoToolbox CVPixelBuffers (NV12 / P010), wrapped zero-copy as Metal textures through
// CVMetalTextureCache and imported into QRhi with QRhiTexture::createFrom().
#include <vector>
#include <array>
#include <QRectF>
#include <QSize>
#include "ClipDecoder.h"

class QRhi;
class QRhiCommandBuffer;
class QRhiRenderTarget;
class QRhiRenderPassDescriptor;
class QRhiBuffer;
class QRhiTexture;
class QRhiSampler;
class QRhiShaderResourceBindings;
class QRhiGraphicsPipeline;

struct LayerParams {
    QRectF rect;          // destination rect in output pixels (top-left origin)
    float opacity = 0.8f;
    float saturation = 1.f;
    float brightness = 0.f;
};

class Compositor {
public:
    Compositor();
    ~Compositor();
    bool init(QRhi *rhi, QRhiRenderPassDescriptor *rp, int maxLayers);
    void release();
    // Records one render pass into rt. `frames[i]` may be null (layer skipped).
    void render(QRhiCommandBuffer *cb, QRhiRenderTarget *rt, const std::vector<FramePtr> &frames,
                const std::vector<LayerParams> &layers);
    // Called when the frame slot is known to be complete (offscreen frames) to drop held buffers.
    void releaseHeld();

    void *metalDevice() const { return m_device; }
    void *textureCache() const { return m_cache; }

private:
    struct Layer {
        QRhiTexture *texY = nullptr, *texUV = nullptr;
        int fmtKey = 0; QSize size;
        QRhiBuffer *ubuf = nullptr;
        QRhiShaderResourceBindings *srb = nullptr;
    };
    struct Held { std::vector<FramePtr> frames; std::vector<void *> cvTextures; };
    void dropSlot(Held &h);

    QRhi *m_rhi = nullptr;
    void *m_device = nullptr;     // id<MTLDevice>
    void *m_cache = nullptr;      // CVMetalTextureCacheRef
    QRhiBuffer *m_vbuf = nullptr;
    QRhiSampler *m_sampler = nullptr;
    QRhiGraphicsPipeline *m_pipeline = nullptr;
    QRhiShaderResourceBindings *m_layoutSrb = nullptr;
    std::vector<Layer> m_layers;
    std::array<Held, 4> m_held;   // per frame-in-flight slot
    bool m_vbufUploaded = false;
    int m_frameCounter = 0;
};
