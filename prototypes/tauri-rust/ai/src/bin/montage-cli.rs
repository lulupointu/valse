//! Headless engine CLI used by bench.sh (export / segmentation / speech-to-text).
//! Same engine code paths as the app; runs them as background jobs would.
use engine::metric_line;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("");
    let media = std::env::var("MONTAGE_MEDIA").unwrap_or_else(|_| "../../bench/media".into());
    let models = std::env::var("MONTAGE_MODELS").unwrap_or_else(|_| "models".into());
    match cmd {
        "export" => {
            let secs: f64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(10.0);
            let out = args.get(3).cloned().unwrap_or_else(|| "out/export.mp4".into());
            let clips: Vec<String> = ["a", "b", "c", "d"].iter().map(|c| format!("{media}/{c}.mp4")).collect();
            let gpu = engine::gpu::Gpu::new()?;
            let st = engine::export::export_bench(gpu, &clips, &out, secs, 1920, 1080, 30)?;
            eprintln!("exported {} frames to {out}", st.frames);
            println!("{}", metric_line("export_seconds", st.seconds, "s"));
        }
        "seg" => {
            let frames: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(300);
            let provider = args.get(3).cloned().unwrap_or_else(|| "coreml".into());
            let st = ai::seg::run_seg_bench(
                &std::env::var("MONTAGE_SEG_MODEL").unwrap_or_else(|_| format!("{models}/rvm_1080p_static.onnx")),
                &format!("{media}/h264_1080.mp4"),
                frames,
                &provider,
            )?;
            eprintln!(
                "seg: {} frames in {:.2}s ({provider}), model load+compile {:.2}s, mean alpha {:.3}",
                st.frames, st.seconds, st.load_seconds, st.mean_alpha
            );
            println!("{}", metric_line("seg_fps", st.fps, "fps"));
        }
        "stt" => {
            let model = std::env::var("MONTAGE_WHISPER").unwrap_or_else(|_| format!("{models}/ggml-large-v3-turbo-q5_0.bin"));
            let r = ai::stt::transcribe(&model, &format!("{media}/speech_fr.wav"), "fr")?;
            eprintln!("stt: {:.1}s audio in {:.2}s (load {:.2}s), {} words", r.audio_seconds, r.seconds, r.load_seconds, r.words.len());
            for w in r.words.iter().take(8) {
                eprintln!("  [{:6.2} - {:6.2}] {}", w.start, w.end, w.text);
            }
            eprintln!("text: {}", r.text.trim());
            println!("{}", metric_line("stt_rtf", r.seconds / r.audio_seconds, "x"));
            let ref_path = std::env::var("MONTAGE_STT_REF").unwrap_or_else(|_| format!("{media}/../speech_fr.txt"));
            if let Ok(reference) = std::fs::read_to_string(&ref_path) {
                println!("{}", metric_line("stt_wer_estimate", ai::stt::wer(&reference, &r.text), "ratio"));
            }
        }
        _ => {
            eprintln!("usage: montage-cli export [secs] [out] | seg [frames] [coreml|cpu] | stt");
            std::process::exit(2);
        }
    }
    Ok(())
}
