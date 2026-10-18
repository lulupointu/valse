#pragma once
#include <string>
#include <vector>

// Offscreen export: same Compositor as the preview, running on a standalone Metal QRhi.
// Render targets are IOSurface-backed CVPixelBuffers (BGRA) that are handed directly to
// h264_videotoolbox as AV_PIX_FMT_VIDEOTOOLBOX frames: decode -> composite -> encode never touches the CPU.
struct ExportResult { bool ok = false; int frames = 0; double seconds = 0; std::string error; };

ExportResult runExport(const std::vector<std::string> &clips, const std::string &outPath,
                       int width, int height, double seconds, int bitrate = 12'000'000);
