// Montage (Qt 6 / C++ prototype) — benchmark driver.
// Modes: preview (P1 + P2 + cold start), audio (P6), timeline (P4), export (P3), seg (P5a), stt (P5b).
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QQuickItem>
#include <QTranslator>
#include <QLocale>
#include <QTimer>
#include <QScreen>
#include <QImage>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonDocument>
#include <QRandomGenerator>
#include <QCommandLineParser>
#include <QDir>
#include <algorithm>
#include <cstdio>
#include <clocale>
#include <memory>

extern "C" {
#include <libavutil/log.h>
}
#include "Metrics.h"
#include "Engine.h"
#include "PreviewItem.h"
#include "TimelineCanvas.h"
#include "Exporter.h"
#include "AudioEngine.h"
#include "Segmenter.h"
#include "Transcriber.h"

namespace {
double percentile(std::vector<double> v, double p)
{
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    double idx = p * (v.size() - 1);
    size_t lo = size_t(idx), hi = std::min(lo + 1, v.size() - 1);
    return v[lo] + (v[hi] - v[lo]) * (idx - lo);
}

struct SwapProbe {
    std::atomic<double> firstFrameEpoch{0};
    std::atomic<uint64_t> displayedGen{0};
    std::atomic<double> displayedAtMs{0};
    std::atomic<long> swaps{0};
    std::atomic<double> lastSwapMs{0};
    std::atomic<long> janky{0};      // intervals > 1.5x the display refresh period
    double periodMs = 16.67;
};

QQuickWindow *loadUi(QQmlApplicationEngine &qml, const QString &mode)
{
    qml.setInitialProperties({{QStringLiteral("mode"), mode}});
    qml.loadFromModule("Montage", "Main");
    if (qml.rootObjects().isEmpty()) return nullptr;
    return qobject_cast<QQuickWindow *>(qml.rootObjects().first());
}

QObject *findByName(QObject *root, const QString &name)
{
    // walks both the QObject tree and the visual item tree (Loader items are not QObject children)
    if (!root) return nullptr;
    if (root->objectName() == name) return root;
    for (QObject *c : root->children())
        if (QObject *r = findByName(c, name)) return r;
    if (auto *item = qobject_cast<QQuickItem *>(root))
        for (QQuickItem *c : item->childItems())
            if (QObject *r = findByName(c, name)) return r;
    return nullptr;
}

void saveScreenshot(QQuickWindow *w, const QString &path)
{
    if (path.isEmpty() || !w) return;
    QImage img = w->grabWindow();
    img.save(path);
    std::fprintf(stderr, "screenshot: %s (%dx%d)\n", qPrintable(path), img.width(), img.height());
}
}

int main(int argc, char **argv)
{
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Montage"));
    av_log_set_level(AV_LOG_ERROR);
    setlocale(LC_NUMERIC, "C"); // JSON output must use "." decimals whatever the UI locale

    QCommandLineParser cli;
    cli.addHelpOption();
    cli.addOptions({
        {"mode", "preview|audio|timeline|export|seg|stt", "mode", "preview"},
        {"media", "media directory", "dir", "../../bench/media"},
        {"seconds", "duration of the measured phase", "s", "5"},
        {"seeks", "number of random seeks", "n", "50"},
        {"frames", "segmentation frames", "n", "300"},
        {"model", "model path", "path"},
        {"out", "output path", "path"},
        {"ref", "reference transcript", "path"},
        {"lang", "UI language (en|fr), default: system", "lang"},
        {"screenshot", "save a window screenshot at the end", "path"},
        {"cpu", "segmentation on CPU EP instead of CoreML"},
        {"rate", "playback rate for audio mode", "r", "1.5"},
    });
    cli.process(app);
    const QString mode = cli.value("mode");
    const QString media = cli.value("media");
    const double seconds = cli.value("seconds").toDouble();
    auto mediaPath = [&](const char *f) { return (media + QLatin1Char('/') + QLatin1String(f)).toStdString(); };

    // French / English UI: compiled .qm embedded as a resource by qt_add_translations
    QTranslator tr;
    const QLocale locale = cli.isSet("lang") ? QLocale(cli.value("lang")) : QLocale::system();
    if (tr.load(locale, QStringLiteral("montage"), QStringLiteral("_"), QStringLiteral(":/i18n")))
        app.installTranslator(&tr);

    // ---------------------------------------------------------------- headless modes
    if (mode == QLatin1String("export")) {
        const std::string out = cli.isSet("out") ? cli.value("out").toStdString() : std::string("/tmp/montage_export.mp4");
        auto r = runExport({mediaPath("a.mp4"), mediaPath("b.mp4"), mediaPath("c.mp4"), mediaPath("d.mp4")}, out, 1920, 1080, seconds);
        if (!r.ok) { std::fprintf(stderr, "export failed: %s (frames=%d)\n", r.error.c_str(), r.frames); return 2; }
        std::fprintf(stderr, "export: %d frames in %.2fs -> %s\n", r.frames, r.seconds, out.c_str());
        metrics::report("export_seconds", r.seconds, "s");
        return 0;
    }
    if (mode == QLatin1String("seg")) {
        auto r = runSegmentation(mediaPath("h264_1080.mp4"), cli.value("model").toStdString(), cli.value("frames").toInt(),
                                 512, 288, QDir::tempPath().toStdString() + "/montage_coreml_cache", !cli.isSet("cpu"));
        if (!r.ok) { std::fprintf(stderr, "seg failed: %s\n", r.error.c_str()); return 2; }
        std::fprintf(stderr, "seg: model=%s provider=%s in=%dx%d load=%.0fms infer=%.2fms/frame e2e=%.1ffps maskMean=%.3f\n",
                     r.model.c_str(), r.provider.c_str(), r.width, r.height, r.loadMs, r.inferMsAvg, r.fps, r.maskMean);
        metrics::report("seg_fps", r.fps, "fps");
        metrics::report("seg_infer_ms", r.inferMsAvg, "ms");
        return 0;
    }
    if (mode == QLatin1String("stt")) {
        auto r = runTranscription(mediaPath("speech_fr.wav"), cli.value("model").toStdString(), cli.value("ref").toStdString());
        if (!r.ok) { std::fprintf(stderr, "stt failed: %s\n", r.error.c_str()); return 2; }
        std::fprintf(stderr, "stt: audio=%.1fs load=%.2fs process=%.2fs words=%zu\ntext:%s\n", r.audioSeconds, r.loadSeconds,
                     r.processSeconds, r.words.size(), r.text.c_str());
        for (size_t i = 0; i < std::min<size_t>(8, r.words.size()); ++i)
            std::fprintf(stderr, "  [%.2f-%.2f] %s\n", r.words[i].t0, r.words[i].t1, r.words[i].text.c_str());
        if (cli.isSet("out")) {
            QJsonArray arr;
            for (auto &w : r.words) arr.append(QJsonObject{{"w", QString::fromStdString(w.text)}, {"t0", w.t0}, {"t1", w.t1}});
            QFile f(cli.value("out")); f.open(QIODevice::WriteOnly);
            f.write(QJsonDocument(QJsonObject{{"text", QString::fromStdString(r.text)}, {"words", arr}}).toJson());
        }
        metrics::report("stt_rtf", r.rtf, "x");
        if (r.wer >= 0) metrics::report("stt_wer_estimate", r.wer, "ratio");
        return 0;
    }

    // ---------------------------------------------------------------- UI modes
    SwapProbe probe;
    std::unique_ptr<Engine> engine;
    std::unique_ptr<AudioEngine> audio;
    const double rate = cli.value("rate").toDouble();
    if (mode == QLatin1String("preview")) {
        // [bench harness] MONTAGE_LAYERS=8 -> a..d twice (8-layer stress test)
        std::vector<std::string> paths{mediaPath("a.mp4"), mediaPath("b.mp4"), mediaPath("c.mp4"), mediaPath("d.mp4")};
        const int nLayers = qEnvironmentVariableIsSet("MONTAGE_LAYERS") ? qEnvironmentVariableIntValue("MONTAGE_LAYERS") : 4;
        for (int i = 4; i < nLayers; ++i) paths.push_back(paths[i % 4]);
        engine = std::make_unique<Engine>(paths);
    } else if (mode == QLatin1String("audio")) {
        engine = std::make_unique<Engine>(std::vector<std::string>{mediaPath("a.mp4")});
        audio = std::make_unique<AudioEngine>();
        if (!audio->load(mediaPath("a.mp4"))) { std::fprintf(stderr, "audio load failed\n"); return 2; }
    } else if (mode != QLatin1String("timeline")) {
        std::fprintf(stderr, "unknown mode\n"); return 1;
    }
    if (engine) {
        if (!engine->open()) return 2;
        engine->start();
        PreviewItem::s_engine = engine.get();
    }

    QQmlApplicationEngine qml;
    QQuickWindow *win = loadUi(qml, mode == QLatin1String("timeline") ? QStringLiteral("timeline") : QStringLiteral("preview"));
    if (!win) { std::fprintf(stderr, "QML load failed\n"); return 2; }
    probe.periodMs = 1000.0 / std::max(30.0, win->screen()->refreshRate());
    QQuickItem *preview = qobject_cast<QQuickItem *>(findByName(win->contentItem(), QStringLiteral("preview")));

    // render-thread hook: frame presented
    QObject::connect(win, &QQuickWindow::frameSwapped, win, [&probe, preview] {
        const double now = metrics::nowMs();
        auto &st = PreviewItem::s_stats;
        if (preview && st.renderedAny && probe.firstFrameEpoch == 0) probe.firstFrameEpoch = metrics::epochMs();
        probe.displayedGen = st.renderedGen.load();
        probe.displayedAtMs = now;
        const double last = probe.lastSwapMs.exchange(now);
        if (last > 0 && now - last > probe.periodMs * 1.5) probe.janky++;
        probe.swaps++;
        if (preview) QMetaObject::invokeMethod(preview, "update", Qt::QueuedConnection); // keep the clock ticking
    }, Qt::DirectConnection);

    metrics::ProcSampler sampler;
    const QString shot = cli.value("screenshot");
    enum Phase { WaitFirst, Play, Scrub, Warm, Anim, Done } phase = WaitFirst;
    double phaseStart = metrics::nowMs(), lastSample = 0;
    std::vector<double> scrubMs;
    int seeksLeft = cli.value("seeks").toInt();
    bool seekPending = false; uint64_t seekGen = 0; double seekT0 = 0;
    QRandomGenerator rng(1234);
    long swaps0 = 0, janky0 = 0;
    const bool isTimeline = mode == QLatin1String("timeline");

    QTimer tick;
    tick.setTimerType(Qt::PreciseTimer);
    tick.setInterval(2);
    QObject::connect(&tick, &QTimer::timeout, [&] {
        const double now = metrics::nowMs();
        // [bench harness fix] the watchdog used to be a flat 20 s, which fired before a 20 s Play phase could end
        if (now - phaseStart > std::max(20000.0, seconds * 1000 + 10000)) {
            std::fprintf(stderr, "phase %d timeout (swaps=%ld renderedAny=%d)\n", int(phase), probe.swaps.load(), int(PreviewItem::s_stats.renderedAny.load()));
            app.exit(3); return;
        }
        switch (phase) {
        case WaitFirst:
            if (isTimeline) {
                if (probe.swaps > 0) {
                    metrics::report("cold_start_ui_ms", metrics::epochMs() - metrics::processStartEpochMs(), "ms");
                    phase = Warm; phaseStart = now;
                }
                break;
            }
            if (probe.firstFrameEpoch > 0) {
                if (mode == QLatin1String("preview"))
                    metrics::report("cold_start_ms", probe.firstFrameEpoch - metrics::processStartEpochMs(), "ms");
                PreviewItem::s_stats.resetPlayback();
                sampler.begin(); lastSample = now;
                if (audio) {
                    audio->start(rate);
                    AudioEngine *a = audio.get();
                    engine->setClockSource([a] { return a->mediaSeconds(); });
                    engine->play(rate);
                } else {
                    engine->play(1.0);
                }
                phase = Play; phaseStart = now;
            }
            break;
        case Play: {
            if (now - lastSample >= 250) { sampler.sample(); lastSample = now; }
            if (now - phaseStart < seconds * 1000) break;
            engine->pause();
            const double el = (now - phaseStart) / 1000.0;
            auto &st = PreviewItem::s_stats;
            const double fps = st.presented / el;
            if (audio) {
                audio->stop();
                const double ratio = audio->measuredRatio(), in = audio->inputPitchHz(), out = audio->outputPitchHz();
                const bool ok = std::abs(ratio - rate) / rate < 0.03 && in > 0 && std::abs(out - in) / in < 0.03;
                std::fprintf(stderr, "audio: backend=%s rate=%.2f measuredRatio=%.3f pitchIn=%.1fHz pitchOut=%.1fHz underruns=%ld videoFps=%.1f (expected %.1f)\n",
                             AudioEngine::backendName(), rate, ratio, in, out, audio->underruns(), fps, 30 * rate);
                metrics::report("audio_stretch_ok", ok ? 1 : 0, "bool");
                metrics::report("audio_video_fps", fps, "fps");
                phase = Done;
                break;
            }
            std::fprintf(stderr, "preview: presented=%lld dropped=%lld in %.2fs, composite cpu-side %.3f ms/frame, display %.0f Hz\n",
                         (long long)st.presented.load(), (long long)st.dropped.load(), el,
                         st.renderCount ? st.renderMsSum / st.renderCount : 0.0, win->screen()->refreshRate());
            metrics::report("preview_fps", fps, "fps");
            metrics::report("preview_dropped_frames", double(st.dropped.load()), "frames");
            metrics::report("preview_cpu_pct", sampler.cpuPercent(), "%");
            metrics::report("preview_rss_mb", sampler.meanRssMb(), "MB");
            metrics::report("preview_rss_peak_mb", sampler.peakRssMb(), "MB");
            saveScreenshot(win, shot);
            phase = Scrub; phaseStart = now;
            break;
        }
        case Scrub:
            if (seekPending) {
                if (probe.displayedGen.load() >= seekGen && probe.displayedAtMs > seekT0) {
                    scrubMs.push_back(probe.displayedAtMs - seekT0);
                    seekPending = false;
                } else if (now - seekT0 > 5000) {
                    std::fprintf(stderr, "seek timeout\n"); scrubMs.push_back(5000); seekPending = false;
                }
                break;
            }
            if (seeksLeft-- > 0) {
                const int64_t maxIdx = int64_t(57 * engine->fps());
                engine->seek(int64_t(rng.bounded(int(maxIdx))));
                seekGen = engine->seekGeneration();
                seekT0 = metrics::nowMs();
                seekPending = true;
                phaseStart = now;
            } else {
                metrics::report("scrub_ms_p50", percentile(scrubMs, 0.5), "ms");
                metrics::report("scrub_ms_p95", percentile(scrubMs, 0.95), "ms");
                phase = Done;
            }
            break;
        case Warm:
            if (now - phaseStart > 800) {
                if (auto *anim = findByName(win->contentItem(), QStringLiteral("benchAnim")))
                    QMetaObject::invokeMethod(anim, "start");
                swaps0 = probe.swaps; janky0 = probe.janky;
                TimelineCanvas::s_paintMsSum = 0; TimelineCanvas::s_paintCount = 0;
                phase = Anim; phaseStart = now;
            }
            break;
        case Anim:
            if (now - phaseStart >= seconds * 1000) {
                const double el = (now - phaseStart) / 1000.0;
                const double fps = (probe.swaps - swaps0) / el;
                std::fprintf(stderr, "timeline: %.1f fps over %.2fs, janky intervals=%ld, display %.0f Hz, updatePaintNode avg %.3f ms\n",
                             fps, el, probe.janky - janky0, win->screen()->refreshRate(),
                             TimelineCanvas::s_paintCount ? TimelineCanvas::s_paintMsSum / TimelineCanvas::s_paintCount : 0.0);
                metrics::report("timeline_fps", fps, "fps");
                saveScreenshot(win, shot);
                phase = Done;
            }
            break;
        case Done:
            tick.stop();
            if (engine) engine->stop();
            app.quit();
            break;
        }
    });
    tick.start();
    const int rc = app.exec();
    PreviewItem::s_engine = nullptr;
    // window/scene graph are torn down by qml's destructor; the engine must outlive the renderer
    return rc;
}
