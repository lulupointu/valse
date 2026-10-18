#include "ClipDecoder.h"
#include <cmath>
#include <cstdio>
#include <chrono>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
}

static AVPixelFormat pickVT(AVCodecContext *, const AVPixelFormat *fmts)
{
    for (const AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; ++p)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    std::fprintf(stderr, "ClipDecoder: VideoToolbox not offered, falling back to software\n");
    return fmts[0];
}

ClipDecoder::ClipDecoder(std::string path, int cap) : m_path(std::move(path)), m_capacity(cap) {}

ClipDecoder::~ClipDecoder()
{
    stop();
    {
        std::lock_guard l(m_mx);
        m_q.clear();
    }
    if (m_ctx) avcodec_free_context(&m_ctx);
    if (m_fmt) avformat_close_input(&m_fmt);
    if (m_hwDevice) av_buffer_unref(&m_hwDevice);
}

bool ClipDecoder::open()
{
    if (avformat_open_input(&m_fmt, m_path.c_str(), nullptr, nullptr) < 0) { m_err = "open failed"; return false; }
    if (avformat_find_stream_info(m_fmt, nullptr) < 0) { m_err = "no stream info"; return false; }
    const AVCodec *codec = nullptr;
    m_stream = av_find_best_stream(m_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (m_stream < 0) { m_err = "no video stream"; return false; }
    AVStream *st = m_fmt->streams[m_stream];
    m_ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(m_ctx, st->codecpar);
    if (av_hwdevice_ctx_create(&m_hwDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) == 0) {
        m_ctx->hw_device_ctx = av_buffer_ref(m_hwDevice);
        m_ctx->get_format = pickVT;
    }
    m_ctx->pkt_timebase = st->time_base;
    if (avcodec_open2(m_ctx, codec, nullptr) < 0) { m_err = "codec open failed"; return false; }
    AVRational fr = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
    m_fps = fr.num ? av_q2d(fr) : 30.0;
    m_tb = av_q2d(st->time_base);
    m_startPts = st->start_time != AV_NOPTS_VALUE ? st->start_time : 0;
    m_w = m_ctx->width; m_h = m_ctx->height;
    m_frameCount = st->nb_frames > 0 ? st->nb_frames : int64_t(m_fmt->duration / 1e6 * m_fps);
    return true;
}

void ClipDecoder::start()
{
    m_stop = false;
    m_thread = std::thread([this] { run(); });
}

void ClipDecoder::stop()
{
    m_stop = true;
    m_cv.notify_all();
    if (m_thread.joinable()) m_thread.join();
}

void ClipDecoder::seek(int64_t frameIndex)
{
    {
        std::lock_guard l(m_mx);
        m_reqIndex = frameIndex;
        m_reqGen++;
    }
    m_cv.notify_all();
}

void ClipDecoder::doSeek(int64_t idx)
{
    AVStream *st = m_fmt->streams[m_stream];
    int64_t ts = m_startPts + int64_t(std::llround(idx / m_fps / m_tb));
    av_seek_frame(m_fmt, m_stream, ts, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(m_ctx);
    (void)st;
    m_skipUntil = idx;
    m_eof = false;
}

void ClipDecoder::run()
{
    pthread_setname_np("ClipDecoder");
    while (!m_stop) {
        {
            std::unique_lock l(m_mx);
            uint64_t g = m_reqGen.load();
            if (g != m_curGen) {
                int64_t idx = m_reqIndex;
                m_curGen = g;
                m_q.clear();
                l.unlock();
                doSeek(idx);
                continue;
            }
            // bounded queue: wait for room (or a seek / stop)
            m_cv.wait(l, [&] {
                return m_stop || m_reqGen.load() != m_curGen || ((int)m_q.size() < m_capacity && !m_eof);
            });
            if (m_stop) break;
            if (m_reqGen.load() != m_curGen) continue;
        }
        if (!decodeOne()) {
            std::lock_guard l(m_mx);
            m_eof = true;
            m_cv.notify_all();
        }
    }
}

bool ClipDecoder::decodeOne()
{
    AVPacket *pkt = av_packet_alloc();
    bool ok = true;
    int r = av_read_frame(m_fmt, pkt);
    if (r < 0) {
        avcodec_send_packet(m_ctx, nullptr); // drain
        ok = false;
    } else if (pkt->stream_index == m_stream) {
        avcodec_send_packet(m_ctx, pkt);
    }
    av_packet_unref(pkt);
    av_packet_free(&pkt);

    for (;;) {
        AVFrame *f = av_frame_alloc();
        int rr = avcodec_receive_frame(m_ctx, f);
        if (rr < 0) { av_frame_free(&f); break; }
        int64_t pts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
        int64_t idx = std::llround((pts - m_startPts) * m_tb * m_fps);
        if (idx < m_skipUntil) { av_frame_free(&f); continue; }
        FramePtr fp(f, [](AVFrame *p) { av_frame_free(&p); });
        std::lock_guard l(m_mx);
        if (m_reqGen.load() != m_curGen) break; // seek requested meanwhile; drop
        m_q.push_back({idx, m_curGen, std::move(fp)});
        m_cv.notify_all();
    }
    return ok;
}

FramePtr ClipDecoder::acquire(int64_t index, bool allowLater, int64_t *gotIndex)
{
    std::lock_guard l(m_mx);
    uint64_t g = m_reqGen.load();
    bool popped = false;
    while (!m_q.empty() && (m_q.front().gen != g || m_q.front().index < index)) {
        // never drop the last frame of the current generation if it is older: keep it for redisplay
        if (m_q.front().gen == g && m_q.size() == 1 && m_eof) break;
        m_q.pop_front();
        popped = true;
    }
    if (popped) m_cv.notify_all();
    if (m_q.empty() || m_q.front().gen != g) return nullptr;
    auto &f = m_q.front();
    if (f.index == index || (allowLater && f.index > index) || (m_eof && m_q.size() == 1)) {
        if (gotIndex) *gotIndex = f.index;
        return f.frame;
    }
    return nullptr;
}

FramePtr ClipDecoder::acquireBlocking(int64_t index, int timeoutMs)
{
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    for (;;) {
        if (auto f = acquire(index, true)) return f;
        std::unique_lock l(m_mx);
        if (m_eof && m_q.empty()) return nullptr;
        bool ready = m_cv.wait_until(l, deadline, [&] {
            return m_eof || (int)m_q.size() >= m_capacity
                || (!m_q.empty() && m_q.back().gen == m_reqGen.load() && m_q.back().index >= index);
        });
        if (!ready) return nullptr;
    }
}
