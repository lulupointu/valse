#include "Metrics.h"
#include <cstdio>
#include <cstring>
#include <chrono>
#include <map>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>

namespace metrics {

void report(const char *metric, double value, const char *unit)
{
    std::printf("{\"stack\":\"qt-cpp\",\"metric\":\"%s\",\"value\":%.3f,\"unit\":\"%s\"}\n", metric, value, unit);
    std::fflush(stdout);
}

double nowMs()
{
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

double epochMs()
{
    timeval tv; gettimeofday(&tv, nullptr);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static double startEpochMsOf(int pid)
{
    proc_bsdinfo info{};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != (int)sizeof(info))
        return 0;
    return info.pbi_start_tvsec * 1000.0 + info.pbi_start_tvusec / 1000.0;
}

double processStartEpochMs() { return startEpochMsOf(getpid()); }

static double machToNs()
{
    static double f = [] { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return double(tb.numer) / tb.denom; }();
    return f;
}

std::vector<int> ProcSampler::pids()
{
    std::vector<int> out{getpid()};
    const double myStart = processStartEpochMs() - 50; // helpers are spawned after us
    int n = proc_listallpids(nullptr, 0);
    std::vector<int> all(n + 64);
    n = proc_listallpids(all.data(), int(all.size() * sizeof(int)));
    for (int i = 0; i < n; ++i) {
        int pid = all[i];
        if (pid <= 0 || pid == getpid()) continue;
        char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_name(pid, name, sizeof(name)) <= 0) continue;
        if (std::strstr(name, "VTDecoderXPCService") || std::strstr(name, "VTEncoderXPCService")
            || std::strstr(name, "MTLCompilerService")) {
            if (startEpochMsOf(pid) >= myStart) out.push_back(pid);
        }
    }
    return out;
}

double ProcSampler::totalCpuNs(std::vector<int> const &p, double *rssBytes)
{
    double cpu = 0, rss = 0;
    for (int pid : p) {
        rusage_info_v2 ri{};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&ri) == 0) {
            cpu += double(ri.ri_user_time + ri.ri_system_time) * machToNs();
            rss += double(ri.ri_resident_size);
        }
    }
    if (rssBytes) *rssBytes = rss;
    return cpu;
}

void ProcSampler::begin()
{
    m_t0 = nowMs();
    m_basePids = pids();
    m_cpu0 = totalCpuNs(m_basePids, nullptr);
    m_rssSum = m_rssPeak = 0; m_rssN = 0;
}

void ProcSampler::sample()
{
    double rss = 0;
    totalCpuNs(pids(), &rss);
    m_rssSum += rss; m_rssN++;
    if (rss > m_rssPeak) m_rssPeak = rss;
}

double ProcSampler::cpuPercent()
{
    // m_cpu0 is the cumulative CPU of pids alive at begin(); helpers spawned later count from 0.
    // Helpers that died in between would be lost: negligible for VT services during playback.
    double cpu = totalCpuNs(pids(), nullptr);
    double dtNs = (nowMs() - m_t0) * 1e6;
    return dtNs > 0 ? 100.0 * (cpu - m_cpu0) / dtNs : 0;
}

double ProcSampler::meanRssMb() const { return m_rssN ? m_rssSum / m_rssN / (1024.0 * 1024.0) : 0; }
double ProcSampler::peakRssMb() const { return m_rssPeak / (1024.0 * 1024.0); }

}
