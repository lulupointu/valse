//! wgpu (Metal backend) device + zero-copy interop with CoreVideo.
//!
//! `CVPixelBuffer` (IOSurface) -> `CVMetalTextureCache` -> `MTLTexture` -> `wgpu::Texture` via
//! `create_texture_from_hal`. No CPU copies, no staging uploads: the decoder's IOSurface is sampled
//! directly by the compositor shader, and the exporter renders straight into the encoder's
//! IOSurface-backed pixel buffers.
use crate::av::SendBox;
use anyhow::{anyhow, Result};
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_core_foundation::CFRetained;
use objc2_core_video::{
    CVMetalTexture, CVMetalTextureCache, CVMetalTextureGetTexture, CVPixelBuffer,
    CVPixelBufferGetHeightOfPlane, CVPixelBufferGetWidthOfPlane, CVPixelBufferGetWidth, CVPixelBufferGetHeight,
};
use objc2_metal::{MTLDevice, MTLPixelFormat, MTLTexture, MTLTextureType};
use std::ptr::NonNull;
use std::sync::Arc;

pub struct Gpu {
    pub instance: wgpu::Instance,
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    tex_cache: SendBox<CFRetained<CVMetalTextureCache>>,
}

impl Gpu {
    pub fn new() -> Result<Arc<Gpu>> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
            ..Default::default()
        }))
        .map_err(|e| anyhow!("no adapter: {e}"))?;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("montage"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::default(),
            ..Default::default()
        }))?;
        let tex_cache = unsafe {
            let hal_dev = device
                .as_hal::<wgpu::hal::api::Metal>()
                .ok_or_else(|| anyhow!("not metal"))?;
            let mtl: &Retained<ProtocolObject<dyn MTLDevice>> = hal_dev.raw_device();
            let mut out: *mut CVMetalTextureCache = std::ptr::null_mut();
            let r = CVMetalTextureCache::create(None, None, mtl, None, NonNull::from(&mut out));
            if r != 0 || out.is_null() {
                return Err(anyhow!("CVMetalTextureCacheCreate failed {r}"));
            }
            CFRetained::from_raw(NonNull::new_unchecked(out))
        };
        Ok(Arc::new(Gpu { instance, adapter, device, queue, tex_cache: SendBox(tex_cache) }))
    }

    /// Wrap one plane of an IOSurface-backed CVPixelBuffer as a wgpu texture (zero copy).
    pub fn wrap_plane(
        &self,
        pb: &CVPixelBuffer,
        plane: usize,
        planar: bool,
        format: wgpu::TextureFormat,
        usage: wgpu::TextureUsages,
    ) -> Result<wgpu::Texture> {
        let (w, h) = if planar {
            (CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane))
        } else {
            (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        };
        let mtl_fmt = match format {
            wgpu::TextureFormat::R8Unorm => MTLPixelFormat::R8Unorm,
            wgpu::TextureFormat::Rg8Unorm => MTLPixelFormat::RG8Unorm,
            wgpu::TextureFormat::Bgra8Unorm => MTLPixelFormat::BGRA8Unorm,
            wgpu::TextureFormat::Rgba8Unorm => MTLPixelFormat::RGBA8Unorm,
            _ => return Err(anyhow!("unsupported format")),
        };
        unsafe {
            let mut out: *mut CVMetalTexture = std::ptr::null_mut();
            let r = CVMetalTextureCache::create_texture_from_image(
                None,
                &self.tex_cache.0,
                pb,
                None,
                mtl_fmt,
                w,
                h,
                plane,
                NonNull::from(&mut out),
            );
            if r != 0 || out.is_null() {
                return Err(anyhow!("CVMetalTextureCacheCreateTextureFromImage failed {r}"));
            }
            let cvtex: CFRetained<CVMetalTexture> = CFRetained::from_raw(NonNull::new_unchecked(out));
            let raw = CVMetalTextureGetTexture(&cvtex);
            let raw: Retained<ProtocolObject<dyn MTLTexture>> = raw.ok_or_else(|| anyhow!("null MTLTexture"))?;
            // Keep the CVMetalTexture (and thus the IOSurface) alive until wgpu frees the texture.
            let keep = SendBox(cvtex);
            let hal_tex = wgpu::hal::metal::Device::texture_from_raw(
                raw,
                format,
                MTLTextureType::Type2D,
                1,
                1,
                wgpu::hal::CopyExtent { width: w as u32, height: h as u32, depth: 1 },
                Some(Box::new(move || drop(keep))),
            );
            let desc = wgpu::TextureDescriptor {
                label: Some("cv-plane"),
                size: wgpu::Extent3d { width: w as u32, height: h as u32, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage,
                view_formats: &[],
            };
            let initial = if usage.contains(wgpu::TextureUsages::RENDER_ATTACHMENT) {
                wgpu::TextureUses::UNINITIALIZED
            } else {
                wgpu::TextureUses::RESOURCE
            };
            Ok(self.device.create_texture_from_hal::<wgpu::hal::api::Metal>(hal_tex, &desc, initial))
        }
    }

    /// NV12 (420v) frame -> (Y, CbCr) textures.
    pub fn wrap_nv12(&self, pb: &CVPixelBuffer) -> Result<(wgpu::Texture, wgpu::Texture)> {
        let y = self.wrap_plane(pb, 0, true, wgpu::TextureFormat::R8Unorm, wgpu::TextureUsages::TEXTURE_BINDING)?;
        let uv = self.wrap_plane(pb, 1, true, wgpu::TextureFormat::Rg8Unorm, wgpu::TextureUsages::TEXTURE_BINDING)?;
        Ok((y, uv))
    }

    /// BGRA pixel buffer (e.g. from the encoder's pool) as a render target.
    pub fn wrap_bgra_target(&self, pb: &CVPixelBuffer) -> Result<wgpu::Texture> {
        self.wrap_plane(pb, 0, false, wgpu::TextureFormat::Bgra8Unorm, wgpu::TextureUsages::RENDER_ATTACHMENT)
    }

    pub fn flush_cache(&self) {
        objc2_core_video::CVMetalTextureCacheFlush(&self.tex_cache.0, 0);
    }

    pub fn wait_idle(&self) {
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
    }
}
