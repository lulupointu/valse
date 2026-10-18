//! Export: same compositor, rendering straight into IOSurface-backed BGRA pixel buffers taken from
//! the AVAssetWriter adaptor pool, encoded by VideoToolbox (hardware H.264) and muxed to MP4.
use crate::av::*;
use crate::compositor::{bench_layer_params, Compositor, LayerInput};
use crate::decode::PIX_BGRA;
use crate::gpu::Gpu;
use crate::source::ClipSource;
use anyhow::{anyhow, Result};
use block2::RcBlock;
use objc2_av_foundation::{
    AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor, AVAssetWriterStatus,
    AVFileTypeMPEG4, AVMediaTypeVideo, AVVideoAverageBitRateKey, AVVideoCodecKey, AVVideoCodecTypeH264,
    AVVideoCompressionPropertiesKey, AVVideoExpectedSourceFrameRateKey, AVVideoHeightKey,
    AVVideoMaxKeyFrameIntervalKey, AVVideoWidthKey,
};
use objc2_core_foundation::CFRetained;
use objc2_core_media::CMTime;
use objc2_core_video::{
    kCVPixelBufferHeightKey, kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey,
    kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferWidthKey, CVPixelBuffer, CVPixelBufferPool,
    CVPixelBufferPoolCreatePixelBuffer,
};
use objc2_foundation::NSDictionary;
use std::ptr::NonNull;
use std::sync::Arc;
use std::time::Duration;

pub struct ExportStats {
    pub frames: u32,
    pub seconds: f64,
}

pub fn export_bench(gpu: Arc<Gpu>, clips: &[String], out_path: &str, seconds: f64, w: u32, h: u32, fps: u32) -> Result<ExportStats> {
    let t0 = std::time::Instant::now();
    let _ = std::fs::remove_file(out_path);
    let comp = Compositor::new(gpu.clone());
    let mut sources: Vec<ClipSource> = clips.iter().map(|c| ClipSource::open(c)).collect::<Result<_>>()?;
    for s in sources.iter_mut() {
        s.play_from(0.0);
    }
    unsafe {
        let url = file_url_new(out_path);
        let writer = AVAssetWriter::assetWriterWithURL_fileType_error(&url, AVFileTypeMPEG4.unwrap())
            .map_err(|e| anyhow!("writer: {:?}", e))?;
        let br = num_i64(12_000_000);
        let efr = num_u32(fps);
        let gop = num_u32(fps * 2);
        let comp_props = dict(&[
            (AVVideoAverageBitRateKey.unwrap(), br.as_ref()),
            (AVVideoExpectedSourceFrameRateKey.unwrap(), efr.as_ref()),
            (AVVideoMaxKeyFrameIntervalKey.unwrap(), gop.as_ref()),
        ]);
        let wn = num_u32(w);
        let hn = num_u32(h);
        let settings = dict(&[
            (AVVideoCodecKey.unwrap(), AVVideoCodecTypeH264.unwrap().as_ref()),
            (AVVideoWidthKey.unwrap(), wn.as_ref()),
            (AVVideoHeightKey.unwrap(), hn.as_ref()),
            (AVVideoCompressionPropertiesKey.unwrap(), comp_props.as_ref()),
        ]);
        let input = AVAssetWriterInput::assetWriterInputWithMediaType_outputSettings(AVMediaTypeVideo.unwrap(), Some(&settings));
        input.setExpectsMediaDataInRealTime(false);
        let fmt = num_u32(PIX_BGRA);
        let yes = num_bool(true);
        let empty: objc2::rc::Retained<NSDictionary<objc2_foundation::NSString, objc2::runtime::AnyObject>> = NSDictionary::new();
        let attrs = dict(&[
            (cf_ns(kCVPixelBufferPixelFormatTypeKey), fmt.as_ref()),
            (cf_ns(kCVPixelBufferWidthKey), wn.as_ref()),
            (cf_ns(kCVPixelBufferHeightKey), hn.as_ref()),
            (cf_ns(kCVPixelBufferMetalCompatibilityKey), yes.as_ref()),
            (cf_ns(kCVPixelBufferIOSurfacePropertiesKey), empty.as_ref()),
        ]);
        let adaptor = AVAssetWriterInputPixelBufferAdaptor::assetWriterInputPixelBufferAdaptorWithAssetWriterInput_sourcePixelBufferAttributes(&input, Some(&attrs));
        writer.addInput(&input);
        if !writer.startWriting() {
            return Err(anyhow!("startWriting: {:?}", writer.error()));
        }
        writer.startSessionAtSourceTime(CMTime::new(0, fps as i32));
        let pool = adaptor.pixelBufferPool().ok_or_else(|| anyhow!("no pool"))?;

        let total = (seconds * fps as f64).round() as u32;
        // 2-deep pipeline: GPU renders frame i while frame i-1 is handed to the encoder.
        let mut inflight: Option<(u32, CFRetained<CVPixelBuffer>, wgpu::SubmissionIndex)> = None;
        let far = std::time::Instant::now() + Duration::from_secs(5);
        for i in 0..=total {
            let mut submitted = None;
            if i < total {
                let t = i as f64 / fps as f64;
                for s in sources.iter_mut() {
                    s.advance_to(t, far);
                }
                let pb = create_pb(&pool)?;
                let target = gpu.wrap_bgra_target(&pb)?;
                let view = target.create_view(&Default::default());
                let params = bench_layer_params(t);
                let frames: Vec<(wgpu::Texture, wgpu::Texture)> = sources
                    .iter()
                    .map(|s| gpu.wrap_nv12(&s.current.as_ref().expect("frame").pb))
                    .collect::<Result<_>>()?;
                let layers: Vec<LayerInput> = frames
                    .iter()
                    .zip(params.iter())
                    .map(|((y, uv), p)| LayerInput { y, uv, params: *p })
                    .collect();
                let mut enc = gpu.device.create_command_encoder(&Default::default());
                comp.encode(&mut enc, &view, (w, h), &layers);
                let idx = gpu.queue.submit([enc.finish()]);
                submitted = Some((i, pb, idx));
            }
            if let Some((fi, pb, idx)) = inflight.take() {
                let _ = gpu.device.poll(wgpu::PollType::Wait { submission_index: Some(idx), timeout: None });
                while !input.isReadyForMoreMediaData() {
                    std::thread::sleep(Duration::from_micros(500));
                }
                if !adaptor.appendPixelBuffer_withPresentationTime(&pb, CMTime::new(fi as i64, fps as i32)) {
                    return Err(anyhow!("append failed: {:?}", writer.error()));
                }
            }
            inflight = submitted;
            if i % 30 == 0 {
                gpu.flush_cache();
            }
        }
        input.markAsFinished();
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let block = RcBlock::new(move || {
            let _ = tx.send(());
        });
        writer.finishWritingWithCompletionHandler(&block);
        rx.recv_timeout(Duration::from_secs(30)).map_err(|_| anyhow!("finishWriting timeout"))?;
        if writer.status() != AVAssetWriterStatus::Completed {
            return Err(anyhow!("writer failed: {:?}", writer.error()));
        }
        Ok(ExportStats { frames: total, seconds: t0.elapsed().as_secs_f64() })
    }
}

fn file_url_new(path: &str) -> objc2::rc::Retained<objc2_foundation::NSURL> {
    let p = std::path::Path::new(path);
    let abs = if p.is_absolute() { p.to_path_buf() } else { std::env::current_dir().unwrap().join(p) };
    objc2_foundation::NSURL::fileURLWithPath(&ns(&abs.to_string_lossy()))
}

fn create_pb(pool: &CVPixelBufferPool) -> Result<CFRetained<CVPixelBuffer>> {
    unsafe {
        let mut out: *mut CVPixelBuffer = std::ptr::null_mut();
        let r = CVPixelBufferPoolCreatePixelBuffer(None, pool, NonNull::from(&mut out));
        if r != 0 || out.is_null() {
            return Err(anyhow!("CVPixelBufferPoolCreatePixelBuffer {r}"));
        }
        Ok(CFRetained::from_raw(NonNull::new_unchecked(out)))
    }
}
