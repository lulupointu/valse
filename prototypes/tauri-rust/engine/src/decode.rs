//! Hardware decode through AVFoundation (AVAssetReader -> VideoToolbox).
//!
//! Frames come out as IOSurface-backed, Metal-compatible NV12 CVPixelBuffers, which the GPU
//! module wraps as Metal textures with zero copies (CVMetalTextureCache).
#![allow(deprecated)]
use crate::av::*;
use anyhow::{anyhow, Context, Result};
use objc2::rc::Retained;
use objc2_av_foundation::{
    AVAssetReader, AVAssetReaderStatus, AVAssetReaderTrackOutput, AVAssetTrack, AVMediaTypeAudio,
    AVMediaTypeVideo, AVURLAsset,
};
use objc2_core_foundation::CFRetained;
use objc2_av_foundation::NSValueAVFoundationExtensions;
use objc2_core_media::{CMTimeRange, kCMTimePositiveInfinity};
use objc2_core_video::{
    kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey,
    kCVPixelBufferPixelFormatTypeKey, CVPixelBuffer,
};
use objc2_foundation::NSDictionary;
use std::ptr::NonNull;

/// '420v' : 8-bit 4:2:0 bi-planar video range (what VideoToolbox emits natively, no conversion).
pub const PIX_420V: u32 = 0x3432_3076;
/// 'BGRA'
pub const PIX_BGRA: u32 = 0x4247_5241;

pub struct VideoFrame {
    pub pts: f64,
    pub pb: CFRetained<CVPixelBuffer>,
}
unsafe impl Send for VideoFrame {}

pub struct VideoReader {
    asset: Retained<AVURLAsset>,
    track: Retained<AVAssetTrack>,
    reader: Option<Retained<AVAssetReader>>,
    output: Option<Retained<AVAssetReaderTrackOutput>>,
    pub duration: f64,
    pub fps: f64,
    pub width: u32,
    pub height: u32,
    pix_fmt: u32,
    start: f64,
    random_access: bool,
}

impl VideoReader {
    pub fn open(path: &str) -> Result<Self> {
        Self::open_with_format(path, PIX_420V)
    }

    pub fn open_with_format(path: &str, pix_fmt: u32) -> Result<Self> {
        unsafe {
            let url = file_url(path);
            let asset = AVURLAsset::URLAssetWithURL_options(&url, None);
            let tracks = asset.tracksWithMediaType(AVMediaTypeVideo.unwrap());
            let track = tracks.firstObject().ok_or_else(|| anyhow!("no video track in {path}"))?;
            let size = track.naturalSize();
            Ok(Self {
                duration: secs(asset.duration()),
                fps: track.nominalFrameRate() as f64,
                width: size.width as u32,
                height: size.height as u32,
                asset,
                track,
                reader: None,
                output: None,
                pix_fmt,
                start: 0.0,
                random_access: false,
            })
        }
    }

    /// (Re)start reading at `t` seconds. AVAssetReader decodes from the preceding sync sample;
    /// frames before `t` are dropped in `next()`.
    pub fn start(&mut self, t: f64) -> Result<()> {
        self.start_range(t, None)
    }

    pub fn start_range(&mut self, t: f64, dur: Option<f64>) -> Result<()> {
        unsafe {
            if let Some(r) = self.reader.take() {
                r.cancelReading();
            }
            let reader = AVAssetReader::assetReaderWithAsset_error(&self.asset)
                .map_err(|e| anyhow!("AVAssetReader: {:?}", e))?;
            let empty: Retained<NSDictionary<objc2_foundation::NSString, objc2::runtime::AnyObject>> =
                NSDictionary::new();
            let fmt = num_u32(self.pix_fmt);
            let yes = num_bool(true);
            let settings = dict(&[
                (cf_ns(kCVPixelBufferPixelFormatTypeKey), fmt.as_ref()),
                (cf_ns(kCVPixelBufferMetalCompatibilityKey), yes.as_ref()),
                (cf_ns(kCVPixelBufferIOSurfacePropertiesKey), empty.as_ref()),
            ]);
            let output = AVAssetReaderTrackOutput::assetReaderTrackOutputWithTrack_outputSettings(
                &self.track,
                Some(&settings),
            );
            output.setAlwaysCopiesSampleData(false);
            output.setSupportsRandomAccess(self.random_access);
            reader.addOutput(&output);
            let start = cmtime(t.max(0.0));
            let duration = match dur {
                Some(d) => cmtime(d),
                None => kCMTimePositiveInfinity,
            };
            reader.setTimeRange(CMTimeRange { start, duration });
            if !reader.startReading() {
                return Err(anyhow!("startReading failed: {:?}", reader.error()));
            }
            self.reader = Some(reader);
            self.output = Some(output);
            self.start = t;
            Ok(())
        }
    }

    /// Scrub mode: one long-lived reader with `supportsRandomAccess`; each seek re-targets the
    /// existing decoder with `resetForReadingTimeRanges` instead of building a new AVAssetReader.
    pub fn seek_random_access(&mut self, t: f64) -> Result<Option<VideoFrame>> {
        let frame = 1.0 / self.fps.max(1.0);
        if !self.random_access || self.output.is_none() {
            self.random_access = true;
            self.start_range(t, Some(frame))?;
        } else {
            let out = self.output.as_ref().unwrap();
            // must drain the current range before re-targeting
            while unsafe { out.copyNextSampleBuffer() }.is_some() {}
            unsafe {
                let range = CMTimeRange { start: cmtime(t.max(0.0)), duration: cmtime(frame) };
                let v = objc2_foundation::NSValue::valueWithCMTimeRange(range);
                let arr = objc2_foundation::NSArray::from_retained_slice(&[v]);
                out.resetForReadingTimeRanges(&arr);
            }
            self.start = t;
        }
        Ok(self.next())
    }

    /// Next decoded frame with pts >= start (minus half a frame).
    pub fn next(&mut self) -> Option<VideoFrame> {
        let out = self.output.as_ref()?;
        let half = 0.5 / self.fps.max(1.0);
        loop {
            let sample = unsafe { out.copyNextSampleBuffer() }?;
            let pts = secs(unsafe { sample.presentation_time_stamp() });
            if pts + half < self.start {
                continue;
            }
            let Some(pb) = (unsafe { sample.image_buffer() }) else {
                continue;
            };
            return Some(VideoFrame { pts, pb });
        }
    }

    pub fn failed(&self) -> bool {
        self.reader
            .as_ref()
            .map(|r| unsafe { r.status() } == AVAssetReaderStatus::Failed)
            .unwrap_or(false)
    }
}

impl Drop for VideoReader {
    fn drop(&mut self) {
        if let Some(r) = self.reader.take() {
            unsafe { r.cancelReading() };
        }
    }
}

/// Decodes the first audio track to interleaved f32 at the requested rate/channels.
pub fn decode_audio(path: &str, rate: u32, channels: u32, max_seconds: f64) -> Result<Vec<f32>> {
    unsafe {
        let url = file_url(path);
        let asset = AVURLAsset::URLAssetWithURL_options(&url, None);
        let tracks = asset.tracksWithMediaType(AVMediaTypeAudio.unwrap());
        let track = tracks.firstObject().context("no audio track")?;
        let reader = AVAssetReader::assetReaderWithAsset_error(&asset)
            .map_err(|e| anyhow!("AVAssetReader: {:?}", e))?;
        // kAudioFormatLinearPCM = 'lpcm'
        let lpcm = num_u32(0x6c70_636d);
        let r = num_f64(rate as f64);
        let ch = num_u32(channels);
        let bits = num_u32(32);
        let yes = num_bool(true);
        let no = num_bool(false);
        let settings = dict(&[
            (&ns("AVFormatIDKey"), lpcm.as_ref()),
            (&ns("AVSampleRateKey"), r.as_ref()),
            (&ns("AVNumberOfChannelsKey"), ch.as_ref()),
            (&ns("AVLinearPCMBitDepthKey"), bits.as_ref()),
            (&ns("AVLinearPCMIsFloatKey"), yes.as_ref()),
            (&ns("AVLinearPCMIsNonInterleaved"), no.as_ref()),
            (&ns("AVLinearPCMIsBigEndianKey"), no.as_ref()),
        ]);
        let output =
            AVAssetReaderTrackOutput::assetReaderTrackOutputWithTrack_outputSettings(&track, Some(&settings));
        reader.addOutput(&output);
        reader.setTimeRange(CMTimeRange { start: cmtime(0.0), duration: cmtime(max_seconds) });
        if !reader.startReading() {
            return Err(anyhow!("audio startReading failed: {:?}", reader.error()));
        }
        let mut out: Vec<f32> = Vec::new();
        while let Some(sample) = output.copyNextSampleBuffer() {
            let Some(bb) = sample.data_buffer() else { continue };
            let len = bb.data_length();
            let n = len / 4;
            let old = out.len();
            out.resize(old + n, 0.0);
            let dst = NonNull::new(out.as_mut_ptr().add(old) as *mut std::ffi::c_void).unwrap();
            bb.copy_data_bytes(0, len, dst);
        }
        Ok(out)
    }
}
