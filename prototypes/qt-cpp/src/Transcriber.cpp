#include "Transcriber.h"
#include "Metrics.h"
#include <whisper.h>
#include <ggml-backend.h>
#include <QCoreApplication>
#include <QDir>
#include <QString>
#include <QStringList>
#include <QFile>
#include <QRegularExpression>
#include <thread>
#include <cstdio>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/channel_layout.h>
}

namespace {
std::vector<float> loadPcm16kMono(const std::string &path)
{
    std::vector<float> pcm;
    AVFormatContext *fmt = nullptr;
    if (avformat_open_input(&fmt, path.c_str(), nullptr, nullptr) < 0) return pcm;
    avformat_find_stream_info(fmt, nullptr);
    const AVCodec *codec = nullptr;
    int si = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(ctx, fmt->streams[si]->codecpar);
    avcodec_open2(ctx, codec, nullptr);
    SwrContext *swr = nullptr;
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
    swr_alloc_set_opts2(&swr, &mono, AV_SAMPLE_FMT_FLT, WHISPER_SAMPLE_RATE, &ctx->ch_layout, ctx->sample_fmt, ctx->sample_rate, 0, nullptr);
    swr_init(swr);
    AVPacket *pkt = av_packet_alloc(); AVFrame *f = av_frame_alloc();
    auto pull = [&] {
        while (avcodec_receive_frame(ctx, f) == 0) {
            int outN = swr_get_out_samples(swr, f->nb_samples);
            size_t off = pcm.size(); pcm.resize(off + outN);
            uint8_t *dst = reinterpret_cast<uint8_t *>(pcm.data() + off);
            int got = swr_convert(swr, &dst, outN, (const uint8_t **)f->extended_data, f->nb_samples);
            pcm.resize(off + std::max(got, 0));
        }
    };
    while (av_read_frame(fmt, pkt) >= 0) { if (pkt->stream_index == si) { avcodec_send_packet(ctx, pkt); pull(); } av_packet_unref(pkt); }
    avcodec_send_packet(ctx, nullptr); pull();
    av_frame_free(&f); av_packet_free(&pkt); swr_free(&swr); avcodec_free_context(&ctx); avformat_close_input(&fmt);
    return pcm;
}

QStringList normWords(const std::string &s)
{
    QString t = QString::fromUtf8(s.c_str()).toLower();
    t.replace(QRegularExpression(QStringLiteral("[^\\p{L}\\p{N}]+")), QStringLiteral(" "));
    return t.split(QLatin1Char(' '), Qt::SkipEmptyParts);
}
}

double wordErrorRate(const std::string &reference, const std::string &hypothesis)
{
    const QStringList r = normWords(reference), h = normWords(hypothesis);
    std::vector<std::vector<int>> d(r.size() + 1, std::vector<int>(h.size() + 1));
    for (int i = 0; i <= r.size(); ++i) d[i][0] = i;
    for (int j = 0; j <= h.size(); ++j) d[0][j] = j;
    for (int i = 1; i <= r.size(); ++i)
        for (int j = 1; j <= h.size(); ++j)
            d[i][j] = std::min({d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1)});
    return r.isEmpty() ? 0 : double(d[r.size()][h.size()]) / r.size();
}

SttResult runTranscription(const std::string &wavPath, const std::string &modelPath, const std::string &refPath)
{
    SttResult res;
    std::vector<float> pcm = loadPcm16kMono(wavPath);
    if (pcm.empty()) { res.error = "cannot read audio"; return res; }
    res.audioSeconds = double(pcm.size()) / WHISPER_SAMPLE_RATE;

    const double tl = metrics::nowMs();
    // ggml backends (Metal, CPU variants) are plugins: load them from the app bundle when deployed,
    // otherwise from the Homebrew libexec dir.
    static bool loaded = [] {
        const QString bundled = QCoreApplication::applicationDirPath() + QStringLiteral("/../Frameworks/ggml");
        if (QDir(bundled).exists()) ggml_backend_load_all_from_path(QDir(bundled).absolutePath().toUtf8().constData());
        else ggml_backend_load_all_from_path("/opt/homebrew/opt/ggml/libexec");
        return true;
    }();
    (void)loaded;
    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = true;
    cp.flash_attn = true;
    whisper_context *ctx = whisper_init_from_file_with_params(modelPath.c_str(), cp);
    if (!ctx) { res.error = "cannot load model"; return res; }
    res.loadSeconds = (metrics::nowMs() - tl) / 1000.0;

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    p.language = "fr";
    p.translate = false;
    p.n_threads = int(std::min(8u, std::max(4u, std::thread::hardware_concurrency() / 2)));
    p.beam_search.beam_size = 5;
    p.token_timestamps = true;
    p.print_progress = false; p.print_realtime = false; p.print_special = false; p.print_timestamps = false;

    const double t0 = metrics::nowMs();
    if (whisper_full(ctx, p, pcm.data(), int(pcm.size())) != 0) { res.error = "whisper_full failed"; whisper_free(ctx); return res; }
    res.processSeconds = (metrics::nowMs() - t0) / 1000.0;
    res.rtf = res.processSeconds / res.audioSeconds;

    const whisper_token eot = whisper_token_eot(ctx);
    for (int s = 0; s < whisper_full_n_segments(ctx); ++s) {
        res.text += whisper_full_get_segment_text(ctx, s);
        for (int k = 0; k < whisper_full_n_tokens(ctx, s); ++k) {
            whisper_token_data td = whisper_full_get_token_data(ctx, s, k);
            if (td.id >= eot) continue; // special / timestamp tokens
            std::string piece = whisper_full_get_token_text(ctx, s, k);
            const bool newWord = res.words.empty() || (!piece.empty() && piece[0] == ' ');
            if (newWord) res.words.push_back({piece.substr(piece.empty() || piece[0] != ' ' ? 0 : 1), td.t0 / 100.0, td.t1 / 100.0});
            else { res.words.back().text += piece; res.words.back().t1 = td.t1 / 100.0; }
        }
    }
    whisper_free(ctx);

    QFile ref(QString::fromStdString(refPath));
    if (ref.open(QIODevice::ReadOnly)) res.wer = wordErrorRate(ref.readAll().toStdString(), res.text);
    res.ok = true;
    return res;
}
