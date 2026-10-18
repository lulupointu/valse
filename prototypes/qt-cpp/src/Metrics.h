#pragma once
#include <string>
#include <vector>
#include <cstdint>

namespace metrics {

// Prints {"stack":"qt-cpp","metric":..,"value":..,"unit":..} on stdout (flushed).
void report(const char *metric, double value, const char *unit);

double nowMs();                 // monotonic ms
double processStartEpochMs();   // kernel-recorded launch time of this process (epoch ms)
double epochMs();

// Samples CPU% and RSS of this process + the VideoToolbox / Metal XPC helper processes
// that were spawned after this process started (VTDecoderXPCService, VTEncoderXPCService...).
class ProcSampler {
public:
    void begin();          // reset counters (cumulative CPU time snapshot)
    void sample();         // record one RSS sample (call ~every 250-500 ms)
    double cpuPercent();   // average CPU % over [begin, now] (100 = one full core)
    double meanRssMb() const;
    double peakRssMb() const;
private:
    struct Snap { double cpuNs = 0; };
    std::vector<int> pids();
    double totalCpuNs(std::vector<int> const &p, double *rssBytes);
    double m_t0 = 0, m_cpu0 = 0;
    std::vector<int> m_basePids;
    double m_rssSum = 0, m_rssPeak = 0; int m_rssN = 0;
};

}
