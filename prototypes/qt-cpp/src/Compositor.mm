#include "Compositor.h"
#include <rhi/qrhi.h>
#include <QFile>
#include <QMatrix4x4>
#include <cstdio>

#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

extern "C" {
#include <libavutil/frame.h>
}

namespace {
struct alignas(16) UBuf {
    float mvp[16];
    float params[4]; // opacity, saturation, brightness, fullRange
};

QShader loadShader(const char *path)
{
    QFile f(QString::fromLatin1(path));
    if (!f.open(QIODevice::ReadOnly)) { std::fprintf(stderr, "missing shader %s\n", path); return {}; }
    return QShader::fromSerialized(f.readAll());
}

const float kQuad[] = { 0, 0,  0, 1,  1, 0,  1, 1 }; // triangle strip, unit square
}

Compositor::Compositor() = default;
Compositor::~Compositor() { release(); }

bool Compositor::init(QRhi *rhi, QRhiRenderPassDescriptor *rp, int maxLayers)
{
    m_rhi = rhi;
    auto *h = static_cast<const QRhiMetalNativeHandles *>(rhi->nativeHandles());
    if (!h || !h->dev) { std::fprintf(stderr, "Compositor: not running on Metal\n"); return false; }
    m_device = (void *)h->dev;
    CVMetalTextureCacheRef cache = nullptr;
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, (id<MTLDevice>)h->dev, nullptr, &cache) != kCVReturnSuccess)
        return false;
    m_cache = cache;

    m_vbuf = rhi->newBuffer(QRhiBuffer::Immutable, QRhiBuffer::VertexBuffer, sizeof(kQuad));
    m_vbuf->create();
    m_vbufUploaded = false;
    m_sampler = rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None,
                                QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge);
    m_sampler->create();

    m_layers.resize(maxLayers);
    for (auto &L : m_layers) {
        L.ubuf = rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(UBuf));
        L.ubuf->create();
        // placeholder textures until real frames arrive
        L.texY = rhi->newTexture(QRhiTexture::R8, QSize(16, 16));
        L.texUV = rhi->newTexture(QRhiTexture::RG8, QSize(8, 8));
        L.texY->create(); L.texUV->create();
        L.srb = rhi->newShaderResourceBindings();
        L.srb->setBindings({
            QRhiShaderResourceBinding::uniformBuffer(0, QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage, L.ubuf),
            QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage, L.texY, m_sampler),
            QRhiShaderResourceBinding::sampledTexture(2, QRhiShaderResourceBinding::FragmentStage, L.texUV, m_sampler),
        });
        L.srb->create();
    }

    m_pipeline = rhi->newGraphicsPipeline();
    QRhiGraphicsPipeline::TargetBlend blend;
    blend.enable = true; // premultiplied alpha "over"
    blend.srcColor = QRhiGraphicsPipeline::One;
    blend.dstColor = QRhiGraphicsPipeline::OneMinusSrcAlpha;
    blend.srcAlpha = QRhiGraphicsPipeline::One;
    blend.dstAlpha = QRhiGraphicsPipeline::OneMinusSrcAlpha;
    m_pipeline->setTargetBlends({blend});
    m_pipeline->setTopology(QRhiGraphicsPipeline::TriangleStrip);
    m_pipeline->setShaderStages({
        {QRhiShaderStage::Vertex, loadShader(":/shaders/shaders/composite.vert.qsb")},
        {QRhiShaderStage::Fragment, loadShader(":/shaders/shaders/composite.frag.qsb")},
    });
    QRhiVertexInputLayout il;
    il.setBindings({{2 * sizeof(float)}});
    il.setAttributes({{0, 0, QRhiVertexInputAttribute::Float2, 0}});
    m_pipeline->setVertexInputLayout(il);
    m_pipeline->setShaderResourceBindings(m_layers[0].srb);
    m_pipeline->setRenderPassDescriptor(rp);
    if (!m_pipeline->create()) { std::fprintf(stderr, "Compositor: pipeline create failed\n"); return false; }
    return true;
}

void Compositor::dropSlot(Held &h)
{
    for (void *t : h.cvTextures) CFRelease((CVMetalTextureRef)t);
    h.cvTextures.clear();
    h.frames.clear();
}

void Compositor::releaseHeld()
{
    for (auto &h : m_held) dropSlot(h);
}

void Compositor::release()
{
    releaseHeld();
    for (auto &L : m_layers) {
        delete L.srb; delete L.ubuf; delete L.texY; delete L.texUV;
    }
    m_layers.clear();
    delete m_pipeline; m_pipeline = nullptr;
    delete m_sampler; m_sampler = nullptr;
    delete m_vbuf; m_vbuf = nullptr;
    if (m_cache) { CFRelease((CVMetalTextureCacheRef)m_cache); m_cache = nullptr; }
}

void Compositor::render(QRhiCommandBuffer *cb, QRhiRenderTarget *rt, const std::vector<FramePtr> &frames,
                        const std::vector<LayerParams> &layers)
{
    const QSize out = rt->pixelSize();
    Held &held = m_held[m_rhi->currentFrameSlot() % m_held.size()];
    dropSlot(held); // the GPU finished with this slot (QRhi waited on its fence in beginFrame)

    QRhiResourceUpdateBatch *u = m_rhi->nextResourceUpdateBatch();
    if (!m_vbufUploaded) { u->uploadStaticBuffer(m_vbuf, kQuad); m_vbufUploaded = true; }

    const QMatrix4x4 corr = m_rhi->clipSpaceCorrMatrix();
    std::vector<int> drawable;
    auto cache = (CVMetalTextureCacheRef)m_cache;

    for (size_t i = 0; i < layers.size() && i < m_layers.size() && i < frames.size(); ++i) {
        AVFrame *f = frames[i].get();
        if (!f) continue;
        auto pb = (CVPixelBufferRef)f->data[3];
        if (!pb) continue;
        Layer &L = m_layers[i];
        const OSType pf = CVPixelBufferGetPixelFormatType(pb);
        const bool tenBit = pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
        const bool fullRange = pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
        const size_t w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0);
        const size_t w2 = CVPixelBufferGetWidthOfPlane(pb, 1), h2 = CVPixelBufferGetHeightOfPlane(pb, 1);

        CVMetalTextureRef ty = nullptr, tuv = nullptr;
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nullptr,
            tenBit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm, w, h, 0, &ty);
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nullptr,
            tenBit ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm, w2, h2, 1, &tuv);
        if (!ty || !tuv) { if (ty) CFRelease(ty); if (tuv) CFRelease(tuv); continue; }
        held.cvTextures.push_back(ty);
        held.cvTextures.push_back(tuv);
        held.frames.push_back(frames[i]);

        const int key = tenBit ? 2 : 1;
        if (L.fmtKey != key || L.size != QSize(int(w), int(h))) {
            delete L.texY; delete L.texUV;
            L.texY = m_rhi->newTexture(tenBit ? QRhiTexture::R16 : QRhiTexture::R8, QSize(int(w), int(h)));
            L.texUV = m_rhi->newTexture(tenBit ? QRhiTexture::RG16 : QRhiTexture::RG8, QSize(int(w2), int(h2)));
            L.fmtKey = key; L.size = QSize(int(w), int(h));
            L.srb->setBindings({
                QRhiShaderResourceBinding::uniformBuffer(0, QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage, L.ubuf),
                QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage, L.texY, m_sampler),
                QRhiShaderResourceBinding::sampledTexture(2, QRhiShaderResourceBinding::FragmentStage, L.texUV, m_sampler),
            });
        }
        // zero-copy import: the QRhiTexture just wraps the IOSurface-backed MTLTexture
        L.texY->createFrom({quint64((uintptr_t)CVMetalTextureGetTexture(ty)), 0});
        L.texUV->createFrom({quint64((uintptr_t)CVMetalTextureGetTexture(tuv)), 0});
        L.srb->create();

        const LayerParams &p = layers[i];
        QMatrix4x4 m; // unit quad -> NDC rect (Y up in NDC; pos.y=0 is the top edge)
        const float x0 = float(p.rect.left() / out.width() * 2 - 1);
        const float x1 = float(p.rect.right() / out.width() * 2 - 1);
        const float y0 = float(1 - p.rect.top() / out.height() * 2);
        const float y1 = float(1 - p.rect.bottom() / out.height() * 2);
        m.translate(x0, y0);
        m.scale(x1 - x0, y1 - y0);
        if (!m_rhi->isYUpInNDC()) { QMatrix4x4 flip; flip.scale(1, -1); m = flip * m; }
        const QMatrix4x4 mvp = corr * m;
        UBuf ub;
        std::memcpy(ub.mvp, mvp.constData(), sizeof(ub.mvp));
        ub.params[0] = p.opacity; ub.params[1] = p.saturation; ub.params[2] = p.brightness; ub.params[3] = fullRange ? 1.f : 0.f;
        u->updateDynamicBuffer(L.ubuf, 0, sizeof(UBuf), &ub);
        drawable.push_back(int(i));
    }

    cb->beginPass(rt, QColor(0, 0, 0, 255), {1.0f, 0}, u);
    cb->setGraphicsPipeline(m_pipeline);
    cb->setViewport({0, 0, float(out.width()), float(out.height())});
    const QRhiCommandBuffer::VertexInput vb(m_vbuf, 0);
    for (int i : drawable) {
        cb->setShaderResources(m_layers[i].srb);
        cb->setVertexInput(0, 1, &vb);
        cb->draw(4);
    }
    cb->endPass();
    if (++m_frameCounter % 120 == 0) CVMetalTextureCacheFlush(cache, 0);
}
