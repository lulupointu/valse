//! French speech-to-text with word timestamps: whisper.cpp (Metal) via whisper-rs.
use anyhow::{anyhow, Result};
use std::time::Instant;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub struct Word {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

pub struct SttResult {
    pub words: Vec<Word>,
    pub text: String,
    pub audio_seconds: f64,
    pub seconds: f64,
    pub load_seconds: f64,
}

pub fn read_wav_16k_mono(path: &str) -> Result<Vec<f32>> {
    let mut r = hound::WavReader::open(path)?;
    let spec = r.spec();
    if spec.sample_rate != 16000 || spec.channels != 1 {
        return Err(anyhow!("expected 16 kHz mono wav, got {} Hz {} ch", spec.sample_rate, spec.channels));
    }
    Ok(match spec.sample_format {
        hound::SampleFormat::Int => r.samples::<i16>().map(|s| s.unwrap() as f32 / 32768.0).collect(),
        hound::SampleFormat::Float => r.samples::<f32>().map(|s| s.unwrap()).collect(),
    })
}

pub fn transcribe(model: &str, wav: &str, lang: &str) -> Result<SttResult> {
    let tl = Instant::now();
    let mut cp = WhisperContextParameters::default();
    cp.use_gpu(true);
    cp.flash_attn(true);
    let ctx = WhisperContext::new_with_params(model, cp).map_err(|e| anyhow!("{e:?}"))?;
    let mut state = ctx.create_state().map_err(|e| anyhow!("{e:?}"))?;
    let load_seconds = tl.elapsed().as_secs_f64();
    let samples = read_wav_16k_mono(wav)?;
    let audio_seconds = samples.len() as f64 / 16000.0;

    let t0 = Instant::now();
    let mut p = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    p.set_language(Some(lang));
    p.set_token_timestamps(true);
    p.set_print_progress(false);
    p.set_print_realtime(false);
    p.set_print_special(false);
    p.set_print_timestamps(false);
    p.set_n_threads(4);
    state.full(p, &samples).map_err(|e| anyhow!("{e:?}"))?;
    let seconds = t0.elapsed().as_secs_f64();

    // Group BPE tokens into words: a token starting with a space begins a new word.
    let mut words: Vec<Word> = Vec::new();
    let mut text = String::new();
    for seg in state.as_iter() {
        text.push_str(&seg.to_str_lossy().map(|s| s.to_string()).unwrap_or_default());
        for i in 0..seg.n_tokens() {
            let Some(tok) = seg.get_token(i) else { continue };
            let s = tok.to_str_lossy().map(|s| s.to_string()).unwrap_or_default();
            if s.starts_with("[_") || s.starts_with("<|") {
                continue;
            }
            let d = tok.token_data();
            let (t0, t1) = (d.t0 as f64 / 100.0, d.t1 as f64 / 100.0);
            if s.starts_with(' ') || words.is_empty() {
                words.push(Word { text: s.trim().to_string(), start: t0, end: t1 });
            } else if let Some(w) = words.last_mut() {
                w.text.push_str(&s);
                w.end = t1;
            }
        }
    }
    words.retain(|w| !w.text.is_empty());
    Ok(SttResult { words, text, audio_seconds, seconds, load_seconds })
}

fn normalize(s: &str) -> Vec<String> {
    s.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '\'' { c } else { ' ' })
        .collect::<String>()
        .replace('\'', " ")
        .split_whitespace()
        .map(|w| w.to_string())
        .collect()
}

/// Word error rate (Levenshtein over normalized words).
pub fn wer(reference: &str, hypothesis: &str) -> f64 {
    let r = normalize(reference);
    let h = normalize(hypothesis);
    let mut d = vec![vec![0usize; h.len() + 1]; r.len() + 1];
    for i in 0..=r.len() {
        d[i][0] = i;
    }
    for j in 0..=h.len() {
        d[0][j] = j;
    }
    for i in 1..=r.len() {
        for j in 1..=h.len() {
            let c = if r[i - 1] == h[j - 1] { 0 } else { 1 };
            d[i][j] = (d[i - 1][j] + 1).min(d[i][j - 1] + 1).min(d[i - 1][j - 1] + c);
        }
    }
    d[r.len()][h.len()] as f64 / r.len().max(1) as f64
}
