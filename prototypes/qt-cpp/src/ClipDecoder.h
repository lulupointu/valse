#pragma once
// FFmpeg demux + VideoToolbox hardware decode on a dedicated thread.
// Output frames stay on the GPU side as CVPixelBuffers (AVFrame::data[3], format AV_PIX_FMT_VIDEOTOOLBOX):
// no CPU copy of pixels anywhere in the decode -> composite path.
#include <memory>
#include <string>
#include <deque>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>

extern "C" {
struct AVFrame;
struct AVFormatContext;
struct AVCodecContext;
struct AVBufferRef;
}

using FramePtr = std::shared_ptr<AVFrame>;

struct DecodedFrame {
    int64_t index = -1;   // frame index from clip start (pts * fps)
    uint64_t gen = 0;     // seek generation this frame belongs to
    FramePtr frame;
};

class ClipDecoder {
public:
    explicit ClipDecoder(std::string path, int queueCapacity = 4);
    ~ClipDecoder();
    bool open();                      // opens demuxer + VT decoder (synchronous)
    void start();                     // starts decode thread from frame 0
    void stop();

    // Seek: asynchronous, GOP-aware (seek to previous keyframe, decode-and-discard up to target).
    void seek(int64_t frameIndex);
    uint64_t generation() const { return m_reqGen.load(); }

    // Non-blocking: drops queued frames older than `index` (current generation only),
    // returns the frame if it is exactly `index` (or the closest following one when allowLater).
    FramePtr acquire(int64_t index, bool allowLater = false, int64_t *gotIndex = nullptr);
    // Blocking variant used by export: waits until frame `index` (or EOF).
    FramePtr acquireBlocking(int64_t index, int timeoutMs = 5000);

    double fps() const { return m_fps; }
    int width() const { return m_w; }
    int height() const { return m_h; }
    int64_t frameCount() const { return m_frameCount; }
    std::string lastError() const { return m_err; }

private:
    void run();
    bool decodeOne();   // reads/decodes some data, pushes frames. false on EOF
    void doSeek(int64_t idx);

    std::string m_path, m_err;
    int m_capacity;
    AVFormatContext *m_fmt = nullptr;
    AVCodecContext *m_ctx = nullptr;
    AVBufferRef *m_hwDevice = nullptr;
    int m_stream = -1;
    double m_fps = 30, m_tb = 0;
    int64_t m_startPts = 0, m_frameCount = 0;
    int m_w = 0, m_h = 0;

    std::thread m_thread;
    std::mutex m_mx;
    std::condition_variable m_cv;
    std::deque<DecodedFrame> m_q;
    std::atomic<bool> m_stop{false};
    std::atomic<uint64_t> m_reqGen{0};
    int64_t m_reqIndex = 0;     // guarded by m_mx
    uint64_t m_curGen = 0;      // decode thread only
    int64_t m_skipUntil = 0;    // decode thread only
    bool m_eof = false;
};
