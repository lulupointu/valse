#include "Segmenter.h"
#include "ClipDecoder.h"
#include "Metrics.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <CoreVideo/CoreVideo.h>
#include <vector>
#include <QString>
#include <QtGlobal>
#include <cstdio>
#include <filesystem>

extern "C" {
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
}

SegResult runSegmentation(const std::string &video, const std::string &modelPath, int nFrames,
                          int inW, int inH, const std::string &cacheDir, bool coreml)
{
    SegResult r;
    r.model = std::filesystem::path(modelPath).filename().string();
    r.width = inW; r.height = inH;
    try {
        Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "seg");
        const bool isRvm = r.model.find("rvm") != std::string::npos;

        Ort::SessionOptions so;
        so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        so.SetIntraOpNumThreads(4);
        {
            // Pin the free (dynamic) dimensions so CoreML gets static shapes and can use the ANE.
            Ort::SessionOptions probeOpts;
            Ort::Session probe(env, modelPath.c_str(), probeOpts);
            for (size_t i = 0; i < probe.GetInputCount(); ++i) {
                Ort::TypeInfo typeInfo = probe.GetInputTypeInfo(i); // keep alive: shape info is a view
                auto info = typeInfo.GetTensorTypeAndShapeInfo();
                std::vector<const char *> dims(info.GetDimensionsCount());
                info.GetSymbolicDimensions(dims.data(), dims.size());
                auto name = probe.GetInputNameAllocated(i, Ort::AllocatorWithDefaultOptions());
                std::fprintf(stderr, "seg input %s:", name.get());
                for (size_t k = 0; k < dims.size(); ++k) std::fprintf(stderr, " %s", dims[k] && *dims[k] ? dims[k] : "?");
                std::fprintf(stderr, "\n");
                if (!isRvm && dims.size() == 4) {
                    if (dims[0] && *dims[0]) so.AddFreeDimensionOverrideByName(dims[0], 1);
                    if (dims[2] && *dims[2]) so.AddFreeDimensionOverrideByName(dims[2], inH);
                    if (dims[3] && *dims[3]) so.AddFreeDimensionOverrideByName(dims[3], inW);
                }
            }
        }
        if (coreml) {
            std::filesystem::create_directories(cacheDir);
            so.AppendExecutionProvider("CoreML", {
                {"ModelFormat", "MLProgram"},
                {"MLComputeUnits", qEnvironmentVariable("MONTAGE_COREML_UNITS", "ALL").toStdString()},
                {"RequireStaticInputShapes", isRvm ? "0" : "1"},
                {"ModelCacheDirectory", cacheDir},
            });
            r.provider = "CoreML(MLProgram," + qEnvironmentVariable("MONTAGE_COREML_UNITS", "ALL").toStdString() + ")";
        } else {
            r.provider = "CPU";
        }
        const double tl = metrics::nowMs();
        Ort::Session session(env, modelPath.c_str(), so);
        r.loadMs = metrics::nowMs() - tl;

        Ort::AllocatorWithDefaultOptions alloc;
        std::vector<std::string> inNames, outNames;
        for (size_t i = 0; i < session.GetInputCount(); ++i) inNames.push_back(session.GetInputNameAllocated(i, alloc).get());
        for (size_t i = 0; i < session.GetOutputCount(); ++i) outNames.push_back(session.GetOutputNameAllocated(i, alloc).get());
        std::vector<const char *> inN, outN;
        for (auto &s : inNames) inN.push_back(s.c_str());
        for (auto &s : outNames) outN.push_back(s.c_str());

        ClipDecoder dec(video, 6);
        if (!dec.open()) { r.error = "open video failed"; return r; }
        dec.start();

        auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<float> input(size_t(3) * inW * inH);
        std::vector<uint8_t> rgb(size_t(3) * inW * inH);
        const int64_t shape[4] = {1, 3, inH, inW};
        SwsContext *sws = nullptr;

        // RVM recurrent state
        std::vector<std::vector<float>> rec(4, std::vector<float>(1, 0.f));
        std::vector<std::vector<int64_t>> recShape(4, std::vector<int64_t>{1, 1, 1, 1});
        float downsample = 1.0f; // input is already small (512x288)

        const int warmup = 3;
        double inferMs = 0, t0 = 0;
        double maskSum = 0;
        for (int n = 0; n < nFrames + warmup; ++n) {
            if (n == warmup) { t0 = metrics::nowMs(); inferMs = 0; }
            FramePtr f = dec.acquireBlocking(n);
            if (!f) { r.error = "decode failed"; break; }
            auto pb = (CVPixelBufferRef)f->data[3];
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            const int w = int(CVPixelBufferGetWidth(pb)), h = int(CVPixelBufferGetHeight(pb));
            sws = sws_getCachedContext(sws, w, h, AV_PIX_FMT_NV12, inW, inH, AV_PIX_FMT_RGB24, SWS_BILINEAR, nullptr, nullptr, nullptr);
            const uint8_t *src[2] = {(const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0), (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1)};
            const int srcStride[2] = {int(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)), int(CVPixelBufferGetBytesPerRowOfPlane(pb, 1))};
            uint8_t *dst[1] = {rgb.data()};
            const int dstStride[1] = {3 * inW};
            sws_scale(sws, src, srcStride, 0, h, dst, dstStride);
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            f.reset();
            const size_t plane = size_t(inW) * inH;
            for (size_t i = 0; i < plane; ++i)
                for (int c = 0; c < 3; ++c) {
                    float v = rgb[i * 3 + c] / 255.f;
                    input[c * plane + i] = isRvm ? v : (v - 0.5f) / 0.5f;
                }

            std::vector<Ort::Value> inputs;
            inputs.push_back(Ort::Value::CreateTensor<float>(mem, input.data(), input.size(), shape, 4));
            if (isRvm) {
                for (int k = 0; k < 4; ++k)
                    inputs.push_back(Ort::Value::CreateTensor<float>(mem, rec[k].data(), rec[k].size(), recShape[k].data(), 4));
                const int64_t one = 1;
                inputs.push_back(Ort::Value::CreateTensor<float>(mem, &downsample, 1, &one, 1));
            }
            const double ti = metrics::nowMs();
            auto outs = session.Run(Ort::RunOptions{nullptr}, inN.data(), inputs.data(), inputs.size(), outN.data(), outN.size());
            inferMs += metrics::nowMs() - ti;
            // matte: MODNet has a single output; RVM: outputs fgr, pha, r1o..r4o
            size_t matteIdx = isRvm ? 1 : 0;
            auto &m = outs[matteIdx];
            const float *md = m.GetTensorData<float>();
            size_t cnt = m.GetTensorTypeAndShapeInfo().GetElementCount();
            double s = 0; for (size_t i = 0; i < cnt; i += 97) s += md[i];
            maskSum += s / double((cnt + 96) / 97);
            if (isRvm) {
                for (int k = 0; k < 4; ++k) {
                    auto &o = outs[2 + k];
                    auto ti2 = o.GetTensorTypeAndShapeInfo();
                    recShape[k] = ti2.GetShape();
                    const float *od = o.GetTensorData<float>();
                    rec[k].assign(od, od + ti2.GetElementCount());
                }
            }
        }
        if (r.error.empty()) {
            double total = metrics::nowMs() - t0;
            r.fps = nFrames / (total / 1000.0);
            r.inferMsAvg = inferMs / nFrames;
            r.maskMean = maskSum / (nFrames + warmup);
            r.ok = true;
        }
        if (sws) sws_freeContext(sws);
        dec.stop();
    } catch (const std::exception &e) {
        r.error = e.what();
    }
    return r;
}
