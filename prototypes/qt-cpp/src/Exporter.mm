#include "Exporter.h"
#include "Engine.h"
#include "Compositor.h"
#include "Metrics.h"
#include <rhi/qrhi.h>
#include <memory>
#include <cstdio>

#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
}

namespace {
void releasePixelBuffer(void *, uint8_t *data) { CVPixelBufferRelease((CVPixelBufferRef)data); }

struct Muxer {
    AVFormatContext *fmt = nullptr;
    AVStream *st = nullptr;
    AVCodecContext *enc = nullptr;
    AVBufferRef *dev = nullptr, *frames = nullptr;
    ~Muxer()
    {
        if (enc) avcodec_free_context(&enc);
        if (frames) av_buffer_unref(&frames);
        if (dev) av_buffer_unref(&dev);
        if (fmt) {
            if (!(fmt->oformat->flags & AVFMT_NOFILE) && fmt->pb) avio_closep(&fmt->pb);
            avformat_free_context(fmt);
        }
    }
    int drain()
    {
        AVPacket *pkt = av_packet_alloc();
        int n = 0;
        while (avcodec_receive_packet(enc, pkt) == 0) {
            av_packet_rescale_ts(pkt, enc->time_base, st->time_base);
            pkt->stream_index = st->index;
            av_interleaved_write_frame(fmt, pkt);
            ++n;
        }
        av_packet_free(&pkt);
        return n;
    }
};
}

ExportResult runExport(const std::vector<std::string> &clips, const std::string &outPath,
                       int W, int H, double seconds, int bitrate)
{
    ExportResult res;
    const double t0 = metrics::nowMs();

    QRhiMetalInitParams params;
    std::unique_ptr<QRhi> rhi(QRhi::create(QRhi::Metal, &params));
    if (!rhi) { res.error = "QRhi Metal create failed"; return res; }

    Engine engine(clips, 6);
    if (!engine.open()) { res.error = "open clips failed"; return res; }
    engine.start();
    const int fps = int(std::lround(engine.fps()));
    const int nFrames = int(std::lround(seconds * fps));

    // --- encoder: h264_videotoolbox fed with VideoToolbox (CVPixelBuffer) frames
    Muxer mx;
    avformat_alloc_output_context2(&mx.fmt, nullptr, nullptr, outPath.c_str());
    const AVCodec *codec = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (!mx.fmt || !codec) { res.error = "no muxer/encoder"; return res; }
    mx.enc = avcodec_alloc_context3(codec);
    mx.enc->width = W; mx.enc->height = H;
    mx.enc->time_base = {1, fps};
    mx.enc->framerate = {fps, 1};
    mx.enc->bit_rate = bitrate;
    mx.enc->gop_size = fps;
    mx.enc->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
    mx.enc->sw_pix_fmt = AV_PIX_FMT_BGRA;
    mx.enc->color_primaries = AVCOL_PRI_BT709;
    mx.enc->color_trc = AVCOL_TRC_BT709;
    mx.enc->colorspace = AVCOL_SPC_BT709;
    mx.enc->color_range = AVCOL_RANGE_MPEG;
    if (mx.fmt->oformat->flags & AVFMT_GLOBALHEADER) mx.enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    av_hwdevice_ctx_create(&mx.dev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0);
    mx.frames = av_hwframe_ctx_alloc(mx.dev);
    auto *fc = (AVHWFramesContext *)mx.frames->data;
    fc->format = AV_PIX_FMT_VIDEOTOOLBOX; fc->sw_format = AV_PIX_FMT_BGRA; fc->width = W; fc->height = H;
    if (av_hwframe_ctx_init(mx.frames) < 0) { res.error = "hwframe ctx init failed"; return res; }
    mx.enc->hw_frames_ctx = av_buffer_ref(mx.frames);
    AVDictionary *opts = nullptr;
    av_dict_set(&opts, "allow_sw", "0", 0);
    av_dict_set(&opts, "profile", "high", 0);
    if (avcodec_open2(mx.enc, codec, &opts) < 0) { av_dict_free(&opts); res.error = "encoder open failed"; return res; }
    av_dict_free(&opts);
    mx.st = avformat_new_stream(mx.fmt, nullptr);
    avcodec_parameters_from_context(mx.st->codecpar, mx.enc);
    mx.st->time_base = mx.enc->time_base;
    if (avio_open(&mx.fmt->pb, outPath.c_str(), AVIO_FLAG_WRITE) < 0) { res.error = "cannot write output"; return res; }
    if (avformat_write_header(mx.fmt, nullptr) < 0) { res.error = "write header failed"; return res; }

    // --- IOSurface-backed render targets
    CVPixelBufferPoolRef pool = nullptr;
    {
        NSDictionary *pbAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(W), (id)kCVPixelBufferHeightKey: @(H),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        NSDictionary *poolAttrs = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @6};
        CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttrs, (__bridge CFDictionaryRef)pbAttrs, &pool);
    }

    Compositor comp;
    CVMetalTextureCacheRef rtCache = nullptr;
    std::unique_ptr<QRhiRenderPassDescriptor> rpDesc;
    std::unique_ptr<QRhiTexture> dummyTex;
    std::unique_ptr<QRhiTextureRenderTarget> dummyRt;
    {
        // a dummy RT of the same format to create the compatible render pass descriptor + pipeline
        dummyTex.reset(rhi->newTexture(QRhiTexture::BGRA8, QSize(W, H), 1, QRhiTexture::RenderTarget));
        dummyTex->create();
        dummyRt.reset(rhi->newTextureRenderTarget({dummyTex.get()}));
        rpDesc.reset(dummyRt->newCompatibleRenderPassDescriptor());
        dummyRt->setRenderPassDescriptor(rpDesc.get());
        dummyRt->create();
        if (!comp.init(rhi.get(), rpDesc.get(), engine.layerCount())) { res.error = "compositor init failed"; return res; }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, (id<MTLDevice>)comp.metalDevice(), nullptr, &rtCache);
    }
    const auto layout = engine.layout(QSize(W, H));

    std::vector<FramePtr> frames(engine.layerCount());
    int written = 0;
    for (int n = 0; n < nFrames; ++n) {
        for (int i = 0; i < engine.layerCount(); ++i) {
            frames[i] = engine.decoder(i)->acquireBlocking(n);
            if (!frames[i]) { std::fprintf(stderr, "export: layer %d missing frame %d\n", i, n); }
        }
        CVPixelBufferRef pb = nullptr;
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb);
        CVMetalTextureRef cvt = nullptr;
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, rtCache, pb, nullptr, MTLPixelFormatBGRA8Unorm, W, H, 0, &cvt);
        std::unique_ptr<QRhiTexture> tex(rhi->newTexture(QRhiTexture::BGRA8, QSize(W, H), 1, QRhiTexture::RenderTarget));
        tex->createFrom({quint64((uintptr_t)CVMetalTextureGetTexture(cvt)), 0});
        std::unique_ptr<QRhiTextureRenderTarget> rt(rhi->newTextureRenderTarget({tex.get()}));
        rt->setRenderPassDescriptor(rpDesc.get());
        rt->create();

        QRhiCommandBuffer *cb = nullptr;
        if (rhi->beginOffscreenFrame(&cb) != QRhi::FrameOpSuccess) { res.error = "beginOffscreenFrame failed"; break; }
        comp.render(cb, rt.get(), frames, layout);
        rhi->endOffscreenFrame(); // waits for GPU completion
        comp.releaseHeld();
        rt.reset(); tex.reset();
        CFRelease(cvt);

        AVFrame *f = av_frame_alloc();
        f->format = AV_PIX_FMT_VIDEOTOOLBOX;
        f->width = W; f->height = H;
        f->data[3] = (uint8_t *)pb;
        f->buf[0] = av_buffer_create((uint8_t *)pb, 1, releasePixelBuffer, nullptr, 0); // owns pb
        f->hw_frames_ctx = av_buffer_ref(mx.frames);
        f->pts = n;
        f->color_primaries = AVCOL_PRI_BT709; f->color_trc = AVCOL_TRC_BT709; f->colorspace = AVCOL_SPC_BT709;
        int r = avcodec_send_frame(mx.enc, f);
        av_frame_free(&f);
        if (r < 0) { char e[128]; av_strerror(r, e, sizeof e); res.error = std::string("send_frame: ") + e; break; }
        written += mx.drain();
    }
    avcodec_send_frame(mx.enc, nullptr);
    written += mx.drain();
    av_write_trailer(mx.fmt);

    engine.stop();
    frames.clear();
    comp.release();
    if (rtCache) CFRelease(rtCache);
    if (pool) CVPixelBufferPoolRelease(pool);
    dummyRt.reset(); rpDesc.reset(); dummyTex.reset();
    rhi.reset();

    res.frames = written;
    res.seconds = (metrics::nowMs() - t0) / 1000.0;
    res.ok = res.error.empty() && written == nFrames;
    if (!res.ok && res.error.empty()) res.error = "frame count mismatch";
    return res;
}
