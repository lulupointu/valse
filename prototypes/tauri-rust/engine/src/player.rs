//! Real-time preview player: owns the clip sources, the compositor and the presentation surface
//! (a CAMetalLayer hosted in a native NSView that sits under the transparent webview).
//! Runs on its own thread; the UI talks to it through a command channel (Tauri commands).
use crate::compositor::{bench_layer_params, Compositor, LayerInput, COMP_FORMAT};
use crate::gpu::Gpu;
use crate::source::ClipSource;
use crossbeam_channel::{unbounded, Receiver, Sender};
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub enum PlayerCmd {
    Resize { width: u32, height: u32 },
    Play { rate: f64 },
    Pause,
    Seek { t: f64, reply: Option<Sender<f64>> },
    ResetStats,
    Stop,
}

#[derive(Default, Clone, Debug)]
pub struct PlayerStats {
    pub presented: u64,
    pub dropped: u64,
    pub late_layers: u64,
    pub since: Option<Instant>,
    pub first_frame_at: Option<Instant>,
    pub media_time: f64,
    pub playing: bool,
}

#[derive(Clone)]
pub struct PlayerHandle {
    tx: Sender<PlayerCmd>,
    pub stats: Arc<Mutex<PlayerStats>>,
}

impl PlayerHandle {
    pub fn send(&self, c: PlayerCmd) {
        let _ = self.tx.send(c);
    }
    pub fn seek_blocking(&self, t: f64) -> f64 {
        let (tx, rx) = crossbeam_channel::bounded(1);
        self.send(PlayerCmd::Seek { t, reply: Some(tx) });
        rx.recv_timeout(Duration::from_secs(5)).unwrap_or(f64::NAN)
    }
}

pub struct PlayerConfig {
    pub clips: Vec<String>,
    pub comp_size: (u32, u32),
    pub fps: f64,
}

pub fn spawn_player(
    gpu: Arc<Gpu>,
    surface: wgpu::Surface<'static>,
    initial_size: (u32, u32),
    cfg: PlayerConfig,
) -> PlayerHandle {
    let (tx, rx) = unbounded();
    let stats = Arc::new(Mutex::new(PlayerStats::default()));
    let st = stats.clone();
    std::thread::Builder::new()
        .name("player".into())
        .spawn(move || {
            if let Err(e) = player_thread(gpu, surface, initial_size, cfg, rx, st) {
                eprintln!("player thread error: {e:?}");
            }
        })
        .unwrap();
    PlayerHandle { tx, stats }
}

struct Presenter {
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
}

fn player_thread(
    gpu: Arc<Gpu>,
    surface: wgpu::Surface<'static>,
    initial_size: (u32, u32),
    cfg: PlayerConfig,
    rx: Receiver<PlayerCmd>,
    stats: Arc<Mutex<PlayerStats>>,
) -> anyhow::Result<()> {
    let caps = surface.get_capabilities(&gpu.adapter);
    let format = caps
        .formats
        .iter()
        .copied()
        .find(|f| *f == wgpu::TextureFormat::Bgra8Unorm)
        .unwrap_or(caps.formats[0]);
    let config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format,
        width: initial_size.0.max(16),
        height: initial_size.1.max(16),
        present_mode: wgpu::PresentMode::Fifo,
        desired_maximum_frame_latency: 2,
        alpha_mode: wgpu::CompositeAlphaMode::Opaque,
        view_formats: vec![],
        color_space: wgpu::SurfaceColorSpace::Auto,
    };
    surface.configure(&gpu.device, &config);
    let mut pres = Presenter { surface, config };

    let mut comp = Compositor::new(gpu.clone());
    let (cw, ch) = cfg.comp_size;
    let comp_tex = gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("comp"),
        size: wgpu::Extent3d { width: cw, height: ch, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: COMP_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let comp_view = comp_tex.create_view(&Default::default());
    let mut sources: Vec<ClipSource> = cfg.clips.iter().map(|c| ClipSource::open(c)).collect::<anyhow::Result<_>>()?;
    let frame_dur = 1.0 / cfg.fps;

    // initial frame
    let mut media_t = 0.0f64;
    scrub_to(&mut sources, media_t);
    render(&gpu, &mut comp, &comp_view, (cw, ch), &sources, media_t, &mut pres)?;
    {
        let mut s = stats.lock();
        s.first_frame_at = Some(Instant::now());
    }

    let mut playing = false;
    let mut rate = 1.0;
    let mut clock_origin = Instant::now();
    let mut media_origin = 0.0;
    let mut tick: u64 = 0;
    let mut frame_counter = 0u64;

    loop {
        // commands
        let cmd = if playing { rx.try_recv().ok() } else { rx.recv().ok().or(Some(PlayerCmd::Stop)) };
        if let Some(c) = cmd {
            match c {
                PlayerCmd::Stop => return Ok(()),
                PlayerCmd::Resize { width, height } => {
                    pres.config.width = width.max(16);
                    pres.config.height = height.max(16);
                    pres.surface.configure(&gpu.device, &pres.config);
                    if !playing {
                        render(&gpu, &mut comp, &comp_view, (cw, ch), &sources, media_t, &mut pres)?;
                    }
                }
                PlayerCmd::Play { rate: r } => {
                    rate = r;
                    playing = true;
                    for s in sources.iter_mut() {
                        s.play_from(media_t);
                    }
                    clock_origin = Instant::now();
                    media_origin = media_t;
                    tick = 0;
                    let mut s = stats.lock();
                    s.playing = true;
                    s.since = Some(clock_origin);
                }
                PlayerCmd::Pause => {
                    playing = false;
                    stats.lock().playing = false;
                }
                PlayerCmd::ResetStats => {
                    let mut s = stats.lock();
                    s.presented = 0;
                    s.dropped = 0;
                    s.late_layers = 0;
                    s.since = Some(Instant::now());
                }
                PlayerCmd::Seek { t, reply } => {
                    let t0 = Instant::now();
                    media_t = t;
                    scrub_to(&mut sources, t);
                    let idx = render(&gpu, &mut comp, &comp_view, (cw, ch), &sources, t, &mut pres)?;
                    let _ = gpu.device.poll(wgpu::PollType::Wait { submission_index: Some(idx), timeout: None });
                    let ms = t0.elapsed().as_secs_f64() * 1000.0;
                    if let Some(r) = reply {
                        let _ = r.send(ms);
                    }
                    if playing {
                        for s in sources.iter_mut() {
                            s.play_from(media_t);
                        }
                        clock_origin = Instant::now();
                        media_origin = media_t;
                        tick = 0;
                    }
                }
            }
            continue;
        }
        if !playing {
            continue;
        }
        // Frame pacing at the composition rate on the wall clock.
        let now = Instant::now();
        let due = clock_origin + Duration::from_secs_f64(tick as f64 * frame_dur);
        if now < due {
            std::thread::sleep(due - now);
        }
        let now = Instant::now();
        let behind = ((now - clock_origin).as_secs_f64() / frame_dur).floor() as u64;
        if behind > tick + 1 {
            // we're late by more than a frame: skip the missed slots (counted as dropped)
            stats.lock().dropped += behind - tick - 1;
            tick = behind;
        }
        let slot_time = clock_origin + Duration::from_secs_f64(tick as f64 * frame_dur);
        media_t = media_origin + (tick as f64 * frame_dur) * rate;
        let deadline = slot_time + Duration::from_secs_f64(frame_dur * 0.6);
        let mut late = 0;
        for s in sources.iter_mut() {
            if !s.advance_to(media_t, deadline) {
                late += 1;
            }
        }
        render(&gpu, &mut comp, &comp_view, (cw, ch), &sources, media_t, &mut pres)?;
        frame_counter += 1;
        if frame_counter % 60 == 0 {
            gpu.flush_cache();
        }
        {
            let mut s = stats.lock();
            s.presented += 1;
            if late > 0 {
                s.late_layers += late;
                s.dropped += 1;
            }
            s.media_time = media_t;
        }
        tick += 1;
    }
}

fn scrub_to(sources: &mut [ClipSource], t: f64) {
    // all clips decode in parallel on their own threads
    for s in sources.iter_mut() {
        s.request_scrub(t);
    }
    for s in sources.iter_mut() {
        s.wait_scrub(Duration::from_secs(3));
    }
}

fn render(
    gpu: &Gpu,
    comp: &mut Compositor,
    comp_view: &wgpu::TextureView,
    comp_size: (u32, u32),
    sources: &[ClipSource],
    t: f64,
    pres: &mut Presenter,
) -> anyhow::Result<wgpu::SubmissionIndex> {
    let params = bench_layer_params(t);
    let frames: Vec<(wgpu::Texture, wgpu::Texture)> = sources
        .iter()
        .filter_map(|s| s.current.as_ref())
        .map(|f| gpu.wrap_nv12(&f.pb))
        .collect::<anyhow::Result<_>>()?;
    let layers: Vec<LayerInput> =
        frames.iter().zip(params.iter()).map(|((y, uv), p)| LayerInput { y, uv, params: *p }).collect();
    let mut enc = gpu.device.create_command_encoder(&Default::default());
    comp.encode(&mut enc, comp_view, comp_size, &layers);
    let frame = match pres.surface.get_current_texture() {
        wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => Some(f),
        _ => {
            pres.surface.configure(&gpu.device, &pres.config);
            None
        }
    };
    if let Some(frame) = frame {
        let view = frame.texture.create_view(&Default::default());
        comp.encode_blit(
            &mut enc,
            comp_view,
            comp_size,
            &view,
            (pres.config.width, pres.config.height),
            pres.config.format,
        );
        let idx = gpu.queue.submit([enc.finish()]);
        gpu.queue.present(frame);
        Ok(idx)
    } else {
        Ok(gpu.queue.submit([enc.finish()]))
    }
}
