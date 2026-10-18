//! Person segmentation with ONNX Runtime (CoreML execution provider) running Robust Video Matting
//! (MobileNetV3, recurrent => temporally stable masks). Frames come from the same AVFoundation
//! decoder as the player, as BGRA (VideoToolbox does the YUV->RGB conversion).
use anyhow::{anyhow, Result};
use engine::decode::{VideoReader, PIX_BGRA};
use objc2_core_video::{
    CVPixelBufferGetBaseAddress, CVPixelBufferGetBytesPerRow, CVPixelBufferGetHeight, CVPixelBufferGetWidth,
    CVPixelBufferLockBaseAddress, CVPixelBufferLockFlags, CVPixelBufferUnlockBaseAddress,
};
use ort::ep;
use ort::session::Session;
use ort::value::Tensor;
use std::time::Instant;

pub struct SegStats {
    pub frames: usize,
    pub seconds: f64,
    pub fps: f64,
    pub load_seconds: f64,
    pub mean_alpha: f64,
}

pub fn build_session(model: &str, provider: &str) -> Result<Session> {
    let env = ort::init().with_name("montage").build().map_err(|e| anyhow!("{e}"))?;
    let mut b = Session::builder(&env)?;
    if provider == "coreml" {
        let cache = std::env::var("MONTAGE_COREML_CACHE").unwrap_or_else(|_| "out/coreml-cache".into());
        let _ = std::fs::create_dir_all(&cache);
        b = b.with_execution_providers([ep::CoreML::default()
            .with_model_format(ep::coreml::ModelFormat::MLProgram)
            .with_compute_units(match std::env::var("MONTAGE_COREML_UNITS").as_deref() {
                Ok("gpu") => ep::coreml::ComputeUnits::CPUAndGPU,
                Ok("ane") => ep::coreml::ComputeUnits::CPUAndNeuralEngine,
                _ => ep::coreml::ComputeUnits::All,
            })
            .with_static_input_shapes(true)
            .with_model_cache_dir(cache)
            .build()
            .error_on_failure()])
            .map_err(|e| anyhow!("{e}"))?;
    }
    let s = b.commit_from_file(model).map_err(|e| anyhow!("{e}"))?;
    Ok(s)
}

/// BGRA pixel buffer -> planar RGB f32 [0,1], NCHW, multithreaded.
fn to_nchw(pb: &objc2_core_video::CVPixelBuffer, dst: &mut [f32]) {
    unsafe {
        CVPixelBufferLockBaseAddress(pb, CVPixelBufferLockFlags::ReadOnly);
        let w = CVPixelBufferGetWidth(pb);
        let h = CVPixelBufferGetHeight(pb);
        let stride = CVPixelBufferGetBytesPerRow(pb);
        let base = CVPixelBufferGetBaseAddress(pb) as *const u8;
        let src = std::slice::from_raw_parts(base, stride * h);
        let plane = w * h;
        let (r, rest) = dst.split_at_mut(plane);
        let (g, b) = rest.split_at_mut(plane);
        let threads = 8;
        let rows_per = h.div_ceil(threads);
        std::thread::scope(|s| {
            let chunks = r.chunks_mut(rows_per * w).zip(g.chunks_mut(rows_per * w)).zip(b.chunks_mut(rows_per * w));
            for (i, ((rc, gc), bc)) in chunks.enumerate() {
                let src = &src;
                s.spawn(move || {
                    let y0 = i * rows_per;
                    for (ry, y) in (y0..(y0 + rows_per).min(h)).enumerate() {
                        let row = &src[y * stride..y * stride + w * 4];
                        let o = ry * w;
                        for x in 0..w {
                            let p = &row[x * 4..x * 4 + 4];
                            bc[o + x] = p[0] as f32 * (1.0 / 255.0);
                            gc[o + x] = p[1] as f32 * (1.0 / 255.0);
                            rc[o + x] = p[2] as f32 * (1.0 / 255.0);
                        }
                    }
                });
            }
        });
        CVPixelBufferUnlockBaseAddress(pb, CVPixelBufferLockFlags::ReadOnly);
    }
}

pub fn run_seg_bench(model: &str, video: &str, frames: usize, provider: &str) -> Result<SegStats> {
    let tl = Instant::now();
    let mut session = build_session(model, provider)?;
    let mut reader = VideoReader::open_with_format(video, PIX_BGRA)?;
    reader.start(0.0)?;
    let (w, h) = (reader.width as usize, reader.height as usize);
    let mut buf = vec![0f32; 3 * w * h];
    // Recurrent state inputs: static models carry their real shapes, the dynamic one starts at [1,1,1,1].
    let input_names: Vec<String> = session.inputs().iter().map(|i| i.name().to_string()).collect();
    let has_ratio = input_names.iter().any(|n| n == "downsample_ratio");
    let mut rec: Vec<Tensor<f32>> = Vec::new();
    for k in ["r1i", "r2i", "r3i", "r4i"] {
        let o = session.inputs().iter().find(|i| i.name() == k).ok_or_else(|| anyhow!("no input {k}"))?;
        let shape: Vec<usize> = o.dtype().tensor_shape().map(|s| s.iter().map(|d| (*d).max(1) as usize).collect()).unwrap_or(vec![1, 1, 1, 1]);
        let n: usize = shape.iter().product();
        rec.push(Tensor::from_array((shape, vec![0f32; n]))?);
    }
    let ratio = Tensor::from_array(([1usize], vec![0.25f32]))?;
    let run = |session: &mut Session, src: ort::value::TensorRef<'_, f32>, rec: &[Tensor<f32>]| -> Result<(f64, Vec<Tensor<f32>>)> {
        let mut inputs: Vec<(String, ort::session::SessionInputValue)> = vec![
            ("src".into(), src.into()),
            ("r1i".into(), rec[0].clone().into()),
            ("r2i".into(), rec[1].clone().into()),
            ("r3i".into(), rec[2].clone().into()),
            ("r4i".into(), rec[3].clone().into()),
        ];
        if has_ratio {
            inputs.push(("downsample_ratio".into(), ratio.clone().into()));
        }
        let out = session.run(inputs)?;
        let (_, pha) = out["pha"].try_extract_tensor::<f32>()?;
        let alpha = pha.iter().step_by(97).map(|v| *v as f64).sum::<f64>() / (pha.len() / 97) as f64;
        let mut next = Vec::with_capacity(4);
        for k in ["r1o", "r2o", "r3o", "r4o"] {
            let (shape, data) = out[k].try_extract_tensor::<f32>()?;
            let dims: Vec<usize> = shape.iter().map(|d| *d as usize).collect();
            next.push(Tensor::from_array((dims, data.to_vec()))?);
        }
        Ok((alpha, next))
    };
    // warm-up (CoreML compiles the model on first run)
    let (_, warm) = run(&mut session, ort::value::TensorRef::from_array_view(([1usize, 3, h, w], &buf[..]))?, &rec)?;
    if !has_ratio {
        drop(warm);
    } else {
        rec = warm;
    }
    let load_seconds = tl.elapsed().as_secs_f64();
    let t0 = Instant::now();
    let mut n = 0;
    let mut alpha_sum = 0.0;
    let mut pre_s = 0.0;
    while n < frames {
        let Some(f) = reader.next() else { break };
        let tp = Instant::now();
        to_nchw(&f.pb, &mut buf);
        pre_s += tp.elapsed().as_secs_f64();
        let (alpha, next) = run(&mut session, ort::value::TensorRef::from_array_view(([1usize, 3, h, w], &buf[..]))?, &rec)?;
        alpha_sum += alpha;
        rec = next;
        n += 1;
    }
    let seconds = t0.elapsed().as_secs_f64();
    eprintln!("seg: preprocess {:.1} ms/frame", pre_s * 1000.0 / n.max(1) as f64);
    Ok(SegStats { frames: n, seconds, fps: n as f64 / seconds, load_seconds, mean_alpha: alpha_sum / n.max(1) as f64 })
}
