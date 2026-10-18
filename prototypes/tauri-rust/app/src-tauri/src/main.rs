// Montage prototype: Tauri 2 shell (WKWebView UI) + Rust engine.
// The preview is a native CAMetalLayer under the transparent webview; the UI only sends the
// player rectangle and transport commands over IPC. No video frames cross the IPC boundary.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use engine::gpu::Gpu;
use engine::player::{spawn_player, PlayerCmd, PlayerConfig, PlayerHandle};
use engine::present::NativePreview;
use parking_lot::Mutex;
use serde::Serialize;
use std::io::Write;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager, State};

#[derive(Clone, Serialize)]
struct BenchConfig {
    mode: String,
    duration: f64,
    lang: String,
}

#[derive(Default)]
struct Ready {
    ui_ready_epoch_ms: Option<f64>,
}

struct AppState {
    player: Mutex<Option<PlayerHandle>>,
    preview: Arc<Mutex<Option<NativePreview>>>,
    bench: BenchConfig,
    ready: Mutex<Ready>,
    results: Mutex<Vec<String>>,
    out_path: Option<String>,
}

fn epoch_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64() * 1000.0
}

fn instant_to_epoch_ms(i: Instant) -> f64 {
    epoch_ms() - i.elapsed().as_secs_f64() * 1000.0
}

#[tauri::command]
fn bench_config(state: State<AppState>) -> BenchConfig {
    state.bench.clone()
}

#[tauri::command]
fn ui_ready(state: State<AppState>) {
    let mut r = state.ready.lock();
    if r.ui_ready_epoch_ms.is_none() {
        r.ui_ready_epoch_ms = Some(epoch_ms());
    }
}

#[tauri::command]
fn set_player_rect(app: AppHandle, state: State<AppState>, x: f64, y: f64, w: f64, h: f64) {
    let preview = state.preview.clone();
    let player = state.player.lock().clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(p) = preview.lock().as_ref() {
            let (pw, ph) = p.set_frame_css(x, y, w, h);
            if let Some(pl) = player {
                pl.send(PlayerCmd::Resize { width: pw, height: ph });
            }
        }
    });
}

#[tauri::command]
fn player_play(state: State<AppState>, rate: Option<f64>) {
    if let Some(p) = state.player.lock().as_ref() {
        p.send(PlayerCmd::Play { rate: rate.unwrap_or(1.0) });
    }
}

#[tauri::command]
fn player_pause(state: State<AppState>) {
    if let Some(p) = state.player.lock().as_ref() {
        p.send(PlayerCmd::Pause);
    }
}

#[tauri::command]
async fn player_seek(state: State<'_, AppState>, t: f64) -> Result<f64, String> {
    let p = state.player.lock().clone();
    match p {
        Some(p) => Ok(tauri::async_runtime::spawn_blocking(move || p.seek_blocking(t)).await.unwrap_or(f64::NAN)),
        None => Err("no player".into()),
    }
}

#[tauri::command]
fn player_time(state: State<AppState>) -> f64 {
    state.player.lock().as_ref().map(|p| p.stats.lock().media_time).unwrap_or(0.0)
}

/// Metric reported by the web UI (timeline bench). Finishes the run in timeline mode.
#[tauri::command]
fn bench_result(app: AppHandle, state: State<AppState>, metric: String, value: f64, unit: String) {
    push_metric(&state, &metric, value, &unit);
    if state.bench.mode == "timeline" {
        finish(&app, &state);
    }
}

fn push_metric(state: &AppState, metric: &str, value: f64, unit: &str) {
    let line = engine::metric_line(metric, value, unit);
    println!("{line}");
    state.results.lock().push(line);
}

fn finish(app: &AppHandle, state: &AppState) {
    if let Some(path) = &state.out_path {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            for l in state.results.lock().iter() {
                let _ = writeln!(f, "{l}");
            }
        }
    }
    if let Some(p) = state.player.lock().as_ref() {
        p.send(PlayerCmd::Stop);
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        app.exit(0);
    });
}

fn clips() -> Vec<String> {
    let media = std::env::var("MONTAGE_MEDIA").unwrap_or_else(|_| "../../bench/media".into());
    // [bench harness] MONTAGE_LAYERS=8 -> a..d twice (8-layer stress test)
    let n: usize = std::env::var("MONTAGE_LAYERS").ok().and_then(|v| v.parse().ok()).unwrap_or(4);
    ["a", "b", "c", "d"].iter().cycle().take(n).map(|c| format!("{media}/{c}.mp4")).collect()
}

/// Wait until both the UI and the first composited frame are up.
fn wait_ready(app: &AppHandle) -> Option<(f64, PlayerHandle)> {
    let state = app.state::<AppState>();
    let t = Instant::now();
    loop {
        let ui = state.ready.lock().ui_ready_epoch_ms;
        let p = state.player.lock().clone();
        if let (Some(ui), Some(p)) = (ui, p) {
            let ff = p.stats.lock().first_frame_at;
            if let Some(ff) = ff {
                return Some((ui.max(instant_to_epoch_ms(ff)), p));
            }
        }
        if t.elapsed() > Duration::from_secs(60) {
            return None;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn run_bench(app: AppHandle) {
    let state = app.state::<AppState>();
    let mode = state.bench.mode.clone();
    let Some((ready_ms, player)) = wait_ready(&app) else {
        eprintln!("bench: app never became ready");
        finish(&app, &state);
        return;
    };
    match mode.as_str() {
        "cold" => {
            if let Some(t0) = std::env::var("MONTAGE_T0_MS").ok().and_then(|v| v.parse::<f64>().ok()) {
                push_metric(&state, "cold_start_ms", ready_ms - t0, "ms");
            }
        }
        "preview" | "audio" => {
            let dur = state.bench.duration;
            let audio_rate = 1.5;
            let audio = if mode == "audio" {
                match engine::audio::play_clip_stretched(&clips()[0], 0.0, audio_rate, dur + 3.0) {
                    Ok(a) => Some(a),
                    Err(e) => {
                        eprintln!("audio failed: {e}");
                        None
                    }
                }
            } else {
                None
            };
            player.send(PlayerCmd::Play { rate: if mode == "audio" { audio_rate } else { 1.0 } });
            // warm-up: let decoders fill, then measure a clean window
            std::thread::sleep(Duration::from_millis(1000));
            player.send(PlayerCmd::ResetStats);
            if let Ok(marker) = std::env::var("MONTAGE_MARKER") {
                let _ = std::fs::write(marker, "playing");
            }
            std::thread::sleep(Duration::from_secs_f64(dur));
            let s = player.stats.lock().clone();
            player.send(PlayerCmd::Pause);
            let elapsed = s.since.map(|i| i.elapsed().as_secs_f64()).unwrap_or(dur);
            if mode == "preview" {
                push_metric(&state, "preview_fps", s.presented as f64 / elapsed, "fps");
                push_metric(&state, "preview_dropped_frames", s.dropped as f64, "frames");
            } else if let Some(a) = audio {
                match engine::audio::verify(&a, &clips()[0], audio_rate) {
                    Ok(c) => {
                        eprintln!(
                            "audio check: in {:.1} Hz out {:.1} Hz consumed/produced {:.3} callbacks {}",
                            c.input_freq, c.output_freq, c.measured_rate, c.callbacks
                        );
                        push_metric(&state, "audio_stretch_ok", if c.ok { 1.0 } else { 0.0 }, "bool");
                    }
                    Err(e) => eprintln!("audio verify: {e}"),
                }
            }
        }
        "scrub" => {
            let n: usize = std::env::var("MONTAGE_SEEKS").ok().and_then(|v| v.parse().ok()).unwrap_or(50);
            // deterministic pseudo-random timestamps
            let mut seed: u64 = 0x9E3779B97F4A7C15;
            let mut lat = Vec::new();
            for _ in 0..n {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                let t = (seed % 55_000) as f64 / 1000.0;
                lat.push(player.seek_blocking(t));
            }
            lat.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let pct = |p: f64| lat[((lat.len() as f64 - 1.0) * p).round() as usize];
            push_metric(&state, "scrub_ms_p50", pct(0.5), "ms");
            push_metric(&state, "scrub_ms_p95", pct(0.95), "ms");
        }
        _ => {}
    }
    finish(&app, &state);
}

fn main() {
    let mode = std::env::var("MONTAGE_BENCH").unwrap_or_default();
    let bench = BenchConfig {
        mode: mode.clone(),
        duration: std::env::var("MONTAGE_DURATION").ok().and_then(|v| v.parse().ok()).unwrap_or(3.0),
        lang: std::env::var("MONTAGE_LANG").unwrap_or_default(),
    };
    let state = AppState {
        player: Mutex::new(None),
        preview: Arc::new(Mutex::new(None)),
        bench,
        ready: Mutex::new(Ready::default()),
        results: Mutex::new(Vec::new()),
        out_path: std::env::var("MONTAGE_OUT").ok(),
    };
    tauri::Builder::default()
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            bench_config,
            ui_ready,
            set_player_rect,
            player_play,
            player_pause,
            player_seek,
            player_time,
            bench_result
        ])
        .setup(move |app| {
            let win = app.get_webview_window("main").expect("main window");
            let gpu = Gpu::new()?;
            let handle = app.handle().clone();
            win.with_webview(move |wv| {
                // runs on the main thread
                let state = handle.state::<AppState>();
                let preview = unsafe { NativePreview::attach_below_webview(wv.inner() as *mut std::ffi::c_void) };
                let preview = match preview {
                    Ok(p) => p,
                    Err(e) => {
                        eprintln!("native preview attach failed: {e}");
                        return;
                    }
                };
                let surface = unsafe { preview.create_surface(&gpu.instance) }.expect("surface");
                let player = spawn_player(
                    gpu.clone(),
                    surface,
                    (1920, 1080),
                    PlayerConfig { clips: clips(), comp_size: (1920, 1080), fps: 30.0 },
                );
                *state.preview.lock() = Some(preview);
                *state.player.lock() = Some(player);
            })?;
            let _ = win.set_focus();
            if !mode.is_empty() && mode != "timeline" {
                let h = app.handle().clone();
                std::thread::spawn(move || run_bench(h));
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
