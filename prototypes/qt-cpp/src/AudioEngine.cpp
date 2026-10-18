#include "AudioEngine.h"
#include "miniaudio.h"
#include <rubberband/RubberBandStretcher.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <chrono>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
}

namespace {
// Lock-free single-producer / single-consumer float ring.
class SpscRing {
public:
    explicit SpscRing(size_t cap) : m_buf(cap), m_cap(cap) {}
    size_t writeSpace() const { return m_cap - 1 - size(); }
    size_t size() const { return (m_w.load(std::memory_order_acquire) + m_cap - m_r.load(std::memory_order_acquire)) % m_cap; }
    void write(const float *src, size_t n)
    {
        size_t w = m_w.load(std::memory_order_relaxed);
        for (size_t i = 0; i < n; ++i) { m_buf[w] = src[i]; w = (w + 1) % m_cap; }
        m_w.store(w, std::memory_order_release);
    }
    size_t read(float *dst, size_t n)
    {
        size_t avail = size(); n = std::min(n, avail);
        size_t r = m_r.load(std::memory_order_relaxed);
        for (size_t i = 0; i < n; ++i) { dst[i] = m_buf[r]; r = (r + 1) % m_cap; }
        m_r.store(r, std::memory_order_release);
        return n;
    }
private:
    std::vector<float> m_buf; size_t m_cap;
    std::atomic<size_t> m_w{0}, m_r{0};
};

void dataCallback(ma_device *dev, void *out, const void *, ma_uint32 frames)
{
    static_cast<AudioEngine *>(dev->pUserData)->render(static_cast<float *>(out), frames);
}
}

struct AudioEngine::Impl {
    ma_device device{};
    bool deviceInit = false;
    std::unique_ptr<RubberBand::RubberBandStretcher> rb;
    SpscRing ring{48000 * 2 / 2}; // ~0.5 s stereo
    size_t startDelay = 0;
};

AudioEngine::AudioEngine() : d(std::make_unique<Impl>()) {}
AudioEngine::~AudioEngine() { stop(); }

const char *AudioEngine::backendName() { return "miniaudio(CoreAudio)+RubberBand R3 realtime"; }

bool AudioEngine::load(const std::string &path)
{
    AVFormatContext *fmt = nullptr;
    if (avformat_open_input(&fmt, path.c_str(), nullptr, nullptr) < 0) return false;
    avformat_find_stream_info(fmt, nullptr);
    const AVCodec *codec = nullptr;
    int si = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (si < 0) { avformat_close_input(&fmt); return false; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(ctx, fmt->streams[si]->codecpar);
    avcodec_open2(ctx, codec, nullptr);
    SwrContext *swr = nullptr;
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    swr_alloc_set_opts2(&swr, &stereo, AV_SAMPLE_FMT_FLT, m_sr, &ctx->ch_layout, ctx->sample_fmt, ctx->sample_rate, 0, nullptr);
    swr_init(swr);
    AVPacket *pkt = av_packet_alloc();
    AVFrame *f = av_frame_alloc();
    auto pull = [&] {
        while (avcodec_receive_frame(ctx, f) == 0) {
            int outN = swr_get_out_samples(swr, f->nb_samples);
            size_t off = m_pcm.size();
            m_pcm.resize(off + size_t(outN) * 2);
            uint8_t *dst = reinterpret_cast<uint8_t *>(m_pcm.data() + off);
            int got = swr_convert(swr, &dst, outN, (const uint8_t **)f->extended_data, f->nb_samples);
            m_pcm.resize(off + size_t(std::max(got, 0)) * 2);
        }
    };
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == si) { avcodec_send_packet(ctx, pkt); pull(); }
        av_packet_unref(pkt);
    }
    avcodec_send_packet(ctx, nullptr); pull();
    av_frame_free(&f); av_packet_free(&pkt); swr_free(&swr);
    avcodec_free_context(&ctx); avformat_close_input(&fmt);
    m_inPitch = estimatePitch(m_pcm.data() + m_sr * 2 / 2, std::min<size_t>(m_pcm.size() / 2 - m_sr / 2, size_t(m_sr) * 2), m_sr);
    return !m_pcm.empty();
}

bool AudioEngine::start(double rate)
{
    m_rate = rate;
    using RB = RubberBand::RubberBandStretcher;
    d->rb = std::make_unique<RB>(size_t(m_sr), 2, RB::OptionProcessRealTime | RB::OptionEngineFiner | RB::OptionPitchHighConsistency,
                                 1.0 / rate, 1.0);
    d->startDelay = d->rb->getStartDelay();
    // pad the start so that output is aligned (recommended by Rubber Band for real-time mode)
    size_t pad = d->rb->getPreferredStartPad();
    std::vector<float> zeros(pad, 0.f);
    const float *padCh[2] = {zeros.data(), zeros.data()};
    if (pad) d->rb->process(padCh, pad, false);
    m_tap.clear(); m_tap.reserve(size_t(m_sr) * 2 * 8);
    m_inputConsumed = 0; m_outputProduced = 0; m_played = 0; m_underruns = 0;
    m_run = true;
    m_feeder = std::thread([this] { feeder(); });

    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = ma_uint32(m_sr);
    cfg.dataCallback = dataCallback;
    cfg.pUserData = this;
    cfg.periodSizeInFrames = 256;
    if (ma_device_init(nullptr, &cfg, &d->device) != MA_SUCCESS) { std::fprintf(stderr, "audio: device init failed\n"); return false; }
    d->deviceInit = true;
    // let the feeder prime the ring a little before starting the device
    for (int i = 0; i < 200 && d->ring.size() < 4096; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    return ma_device_start(&d->device) == MA_SUCCESS;
}

void AudioEngine::stop()
{
    if (d->deviceInit) { ma_device_uninit(&d->device); d->deviceInit = false; }
    m_run = false;
    if (m_feeder.joinable()) m_feeder.join();
}

void AudioEngine::feeder()
{
    pthread_setname_np("AudioFeeder");
    std::vector<float> L(4096), R(4096), inter(8192);
    const size_t totalIn = m_pcm.size() / 2;
    size_t inPos = 0;
    while (m_run) {
        size_t space = d->ring.writeSpace() / 2;
        if (space < 512) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
        int avail = d->rb->available();
        if (avail > 0) {
            size_t n = std::min({size_t(avail), space, L.size()});
            float *outCh[2] = {L.data(), R.data()};
            n = d->rb->retrieve(outCh, n);
            for (size_t i = 0; i < n; ++i) { inter[2 * i] = L[i]; inter[2 * i + 1] = R[i]; }
            d->ring.write(inter.data(), n * 2);
            m_outputProduced += long(n);
            if (m_tap.size() + n * 2 <= m_tap.capacity()) m_tap.insert(m_tap.end(), inter.begin(), inter.begin() + long(n * 2));
            continue;
        }
        if (inPos >= totalIn) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
        size_t req = d->rb->getSamplesRequired();
        if (req == 0) req = 512;
        req = std::min({req, L.size(), totalIn - inPos});
        for (size_t i = 0; i < req; ++i) { L[i] = m_pcm[2 * (inPos + i)]; R[i] = m_pcm[2 * (inPos + i) + 1]; }
        const float *inCh[2] = {L.data(), R.data()};
        inPos += req;
        d->rb->process(inCh, req, inPos >= totalIn);
        m_inputConsumed += long(req);
    }
}

void AudioEngine::render(float *out, unsigned frames)
{
    // Real-time thread: no locks, no allocations.
    size_t got = d->ring.read(out, size_t(frames) * 2) / 2;
    if (got < frames) { std::memset(out + got * 2, 0, (frames - got) * 2 * sizeof(float)); m_underruns++; }
    for (size_t i = 0; i < got * 2; ++i) out[i] *= 0.25f; // keep the test tone quiet
    m_played += long(got);
}

double AudioEngine::mediaSeconds() const
{
    double outFrames = double(m_played.load()) - double(d->startDelay);
    if (outFrames < 0) outFrames = 0;
    return outFrames * m_rate / m_sr;
}

double AudioEngine::measuredRatio() const
{
    double out = double(m_outputProduced.load()) + double(d->startDelay);
    return out > 0 ? double(m_inputConsumed.load()) / out : 0;
}

double AudioEngine::outputPitchHz() const
{
    size_t frames = m_tap.size() / 2;
    size_t skip = size_t(m_sr) / 2 + d->startDelay;
    if (frames <= skip + 4800) return 0;
    return estimatePitch(m_tap.data() + skip * 2, frames - skip, m_sr);
}

double AudioEngine::estimatePitch(const float *stereo, size_t frames, int sr)
{
    // zero-crossing rate of the left channel (test media is a pure sine tone)
    long crossings = 0;
    for (size_t i = 1; i < frames; ++i)
        if ((stereo[2 * (i - 1)] < 0) != (stereo[2 * i] < 0)) ++crossings;
    return frames ? crossings / 2.0 / (double(frames) / sr) : 0;
}
