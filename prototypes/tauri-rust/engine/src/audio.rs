//! Audio playback: cpal output stream + Signalsmith Stretch (time-stretch with pitch preserved).
//! The stretcher runs inside the real-time callback with pre-allocated buffers (no locks, no
//! allocation on the audio thread). The playback rate is an atomic so it can follow a speed curve.
use crate::decode::decode_audio;
use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use parking_lot::Mutex;
use signalsmith_stretch::Stretch;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub struct AudioPlayback {
    _stream: cpal::Stream,
    pub rate_bits: Arc<AtomicU64>,
    pub consumed_frames: Arc<AtomicU64>,
    pub produced_frames: Arc<AtomicU64>,
    pub callbacks: Arc<AtomicU64>,
    pub capture: Arc<Mutex<Vec<f32>>>,
    pub sample_rate: u32,
    pub channels: u16,
}

impl AudioPlayback {
    pub fn set_rate(&self, r: f64) {
        self.rate_bits.store(r.to_bits(), Ordering::Relaxed);
    }
}

pub fn play_clip_stretched(path: &str, start_s: f64, rate: f64, max_seconds: f64) -> Result<AudioPlayback> {
    let host = cpal::default_host();
    let device = host.default_output_device().ok_or_else(|| anyhow!("no output device"))?;
    let cfg = device.default_output_config()?;
    let sr = cfg.sample_rate();
    let ch = cfg.channels();
    let pcm = Arc::new(decode_audio(path, sr, ch as u32, start_s + max_seconds)?);
    let start_frame = (start_s * sr as f64) as usize;
    let rate_bits = Arc::new(AtomicU64::new(rate.to_bits()));
    let consumed = Arc::new(AtomicU64::new(0));
    let produced = Arc::new(AtomicU64::new(0));
    let callbacks = Arc::new(AtomicU64::new(0));
    let capture = Arc::new(Mutex::new(Vec::with_capacity(sr as usize * ch as usize * 10)));
    let mut stretch = Stretch::preset_default(ch as u32, sr);
    let (rb, cs, ps, cb, cap) = (rate_bits.clone(), consumed.clone(), produced.clone(), callbacks.clone(), capture.clone());
    let mut pos = start_frame as f64;
    let chn = ch as usize;
    let silence = vec![0.0f32; 16384 * chn];
    let stream_cfg: cpal::StreamConfig = cfg.clone().into();
    let stream = device.build_output_stream(
        stream_cfg,
        move |out: &mut [f32], _| {
            cb.fetch_add(1, Ordering::Relaxed);
            let rate = f64::from_bits(rb.load(Ordering::Relaxed));
            let out_frames = out.len() / chn;
            let in_frames = ((out_frames as f64) * rate).round() as usize;
            let total = pcm.len() / chn;
            let p = pos as usize;
            let input: &[f32] = if p + in_frames <= total {
                &pcm[p * chn..(p + in_frames) * chn]
            } else {
                &silence[..(in_frames * chn).min(silence.len())]
            };
            stretch.process(input, &mut *out);
            pos += in_frames as f64;
            cs.fetch_add(in_frames as u64, Ordering::Relaxed);
            ps.fetch_add(out_frames as u64, Ordering::Relaxed);
            if let Some(mut c) = cap.try_lock() {
                if c.len() + out.len() <= c.capacity() {
                    c.extend_from_slice(out);
                }
            }
        },
        |e| eprintln!("audio stream error: {e}"),
        None,
    )?;
    stream.play()?;
    Ok(AudioPlayback {
        _stream: stream,
        rate_bits,
        consumed_frames: consumed,
        produced_frames: produced,
        callbacks,
        capture,
        sample_rate: sr,
        channels: ch,
    })
}

/// Estimate the dominant frequency of channel 0 with zero crossings (fine for a pure tone).
pub fn estimate_freq(interleaved: &[f32], channels: usize, sr: u32) -> f64 {
    let mono: Vec<f32> = interleaved.chunks(channels).map(|c| c[0]).collect();
    // skip the stretcher's latency / fade-in
    let skip = (sr as usize / 2).min(mono.len() / 2);
    let s = &mono[skip..];
    let mut crossings = 0usize;
    for w in s.windows(2) {
        if w[0] <= 0.0 && w[1] > 0.0 {
            crossings += 1;
        }
    }
    crossings as f64 / (s.len() as f64 / sr as f64)
}

/// Check that 1.5x playback preserved the pitch of the source tone and consumed input at 1.5x.
pub struct StretchCheck {
    pub ok: bool,
    pub input_freq: f64,
    pub output_freq: f64,
    pub measured_rate: f64,
    pub callbacks: u64,
}

pub fn verify(p: &AudioPlayback, path: &str, rate: f64) -> Result<StretchCheck> {
    let src = decode_audio(path, p.sample_rate, p.channels as u32, 3.0)?;
    let input_freq = estimate_freq(&src, p.channels as usize, p.sample_rate);
    let cap = p.capture.lock().clone();
    let output_freq = estimate_freq(&cap, p.channels as usize, p.sample_rate);
    let c = p.consumed_frames.load(Ordering::Relaxed) as f64;
    let o = p.produced_frames.load(Ordering::Relaxed) as f64;
    let measured_rate = if o > 0.0 { c / o } else { 0.0 };
    let callbacks = p.callbacks.load(Ordering::Relaxed);
    let ok = callbacks > 10
        && (output_freq / input_freq - 1.0).abs() < 0.03
        && (measured_rate / rate - 1.0).abs() < 0.03;
    Ok(StretchCheck { ok, input_freq, output_freq, measured_rate, callbacks })
}
