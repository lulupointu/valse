#pragma once
#include <string>

// Person segmentation benchmark: VideoToolbox decode -> CPU resize/normalize -> ONNX Runtime (CoreML EP).
struct SegResult {
    bool ok = false;
    double fps = 0;          // end-to-end (decode + preprocess + inference) over `frames`
    double inferMsAvg = 0;   // inference only
    double loadMs = 0;       // session creation (CoreML compile) time
    double maskMean = 0;     // sanity value
    std::string provider, error, model;
    int width = 0, height = 0;
};

SegResult runSegmentation(const std::string &video, const std::string &modelPath, int frames,
                          int inW, int inH, const std::string &cacheDir, bool coreml = true);
