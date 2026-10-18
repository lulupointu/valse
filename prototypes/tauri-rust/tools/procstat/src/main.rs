//! Samples CPU% and RSS of a process *and its helpers*: descendants (by ppid) plus the XPC
//! helper processes launched on its behalf (launchd children, so not descendants):
//! WebKit WebContent / GPU / Networking and VideoToolbox decoder/encoder services.
//! Helpers are identified as "new since launch" (pid absent from <before_file>, a snapshot
//! taken right before the app was started) + a known helper name.
//! Usage: procstat <pid> <seconds> <interval_ms> <before_file>
//! Prints: cpu_pct_avg rss_mb_avg rss_mb_max n_procs then per-process "name:cpu%:rssMB".
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

const HELPERS: &[&str] = &["com.apple.WebKit", "VTDecoderXPCService", "VTEncoderXPCService", "com.apple.audio"];

extern "C" {
    fn mach_timebase_info(info: *mut MachTimebase) -> libc::c_int;
}
#[repr(C)]
struct MachTimebase { numer: u32, denom: u32 }

fn all_pids() -> Vec<i32> {
    let mut pids = vec![0i32; 8192];
    let n = unsafe { libc::proc_listallpids(pids.as_mut_ptr() as *mut _, (pids.len() * 4) as i32) };
    pids.truncate(n.max(0) as usize);
    pids
}

fn ppid(pid: i32) -> Option<i32> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let sz = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    let r = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, &mut info as *mut _ as *mut _, sz) };
    if r == sz { Some(info.pbi_ppid as i32) } else { None }
}

fn name(pid: i32) -> String {
    let mut buf = [0u8; 256];
    let n = unsafe { libc::proc_name(pid, buf.as_mut_ptr() as *mut _, 256) };
    String::from_utf8_lossy(&buf[..n.max(0) as usize]).to_string()
}

/// (cpu time ns, rss bytes)
fn task(pid: i32, tb: f64) -> Option<(f64, u64)> {
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let sz = std::mem::size_of::<libc::proc_taskinfo>() as i32;
    let r = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTASKINFO, 0, &mut info as *mut _ as *mut _, sz) };
    if r == sz {
        Some(((info.pti_total_user + info.pti_total_system) as f64 * tb, info.pti_resident_size))
    } else {
        None
    }
}

fn family(root: i32, before: &HashSet<i32>) -> HashSet<i32> {
    let pids = all_pids();
    let mut set = HashSet::new();
    set.insert(root);
    let parents: HashMap<i32, i32> = pids.iter().filter_map(|&p| ppid(p).map(|pp| (p, pp))).collect();
    for &p in &pids {
        if !before.contains(&p) && p != root {
            let n = name(p);
            if HELPERS.iter().any(|h| n.starts_with(h)) {
                set.insert(p);
            }
        }
    }
    loop {
        let len = set.len();
        for &p in &pids {
            if !set.contains(&p) && parents.get(&p).map(|pp| set.contains(pp)).unwrap_or(false) {
                set.insert(p);
            }
        }
        if set.len() == len { break; }
    }
    set
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let pid: i32 = args[1].parse().unwrap();
    let secs: f64 = args[2].parse().unwrap();
    let interval = Duration::from_millis(args.get(3).and_then(|s| s.parse().ok()).unwrap_or(250));
    let before: HashSet<i32> = args
        .get(4)
        .and_then(|f| std::fs::read_to_string(f).ok())
        .map(|s| s.split_whitespace().filter_map(|t| t.parse().ok()).collect())
        .unwrap_or_default();
    let mut per: HashMap<String, (f64, f64, usize)> = HashMap::new();
    let mut tbi = MachTimebase { numer: 1, denom: 1 };
    unsafe { mach_timebase_info(&mut tbi) };
    let tb = tbi.numer as f64 / tbi.denom as f64;
    let start = Instant::now();
    let mut prev: HashMap<i32, f64> = HashMap::new();
    let mut prev_t = Instant::now();
    let mut cpu_samples = Vec::new();
    let mut rss_samples = Vec::new();
    let mut names = HashSet::new();
    let mut first = true;
    while start.elapsed().as_secs_f64() < secs {
        let fam = family(pid, &before);
        if !fam.contains(&pid) || task(pid, tb).is_none() { break; }
        let now = Instant::now();
        let dt = (now - prev_t).as_secs_f64() * 1e9;
        let mut cpu_ns = 0.0;
        let mut rss = 0u64;
        let mut cur = HashMap::new();
        for &p in &fam {
            if let Some((c, r)) = task(p, tb) {
                let nm = name(p);
                let e = per.entry(nm).or_insert((0.0, 0.0, 0));
                if let Some(pc) = prev.get(&p) { cpu_ns += c - pc; if !first { e.0 += (c - pc) / dt * 100.0; } }
                if !first { e.1 += r as f64 / 1048576.0; e.2 += 1; }
                cur.insert(p, c);
                rss += r;
                names.insert(name(p));
            }
        }
        if !first {
            cpu_samples.push(cpu_ns / dt * 100.0);
            rss_samples.push(rss as f64 / 1048576.0);
        }
        first = false;
        prev = cur;
        prev_t = now;
        std::thread::sleep(interval);
    }
    let avg = |v: &Vec<f64>| if v.is_empty() { 0.0 } else { v.iter().sum::<f64>() / v.len() as f64 };
    let max = rss_samples.iter().cloned().fold(0.0, f64::max);
    let ns = cpu_samples.len().max(1) as f64;
    let mut parts: Vec<String> = per
        .iter()
        .map(|(k, v)| format!("{}:{:.1}%:{:.0}MB", k, v.0 / ns, v.1 / ns))
        .collect();
    parts.sort();
    println!("{:.2} {:.1} {:.1} {} {}", avg(&cpu_samples), avg(&rss_samples), max, names.len(), parts.join(","));
}
