//! Presentation on macOS: a native layer-backed NSView with a CAMetalLayer, inserted in the window
//! *below* the (transparent) WKWebView. The webview leaves a transparent hole where the player
//! is; HTML controls/handles can be drawn on top of the video. Frames never cross IPC: the
//! compositor renders into the CAMetalLayer drawable directly from the render thread.
use objc2::rc::Retained;
use objc2::MainThreadMarker;
use objc2_app_kit::{NSView, NSWindowOrderingMode};
use objc2_foundation::{NSPoint, NSRect, NSSize};
use objc2_quartz_core::CAMetalLayer;
use std::ffi::c_void;

pub struct NativePreview {
    pub view: Retained<NSView>,
    pub layer: Retained<CAMetalLayer>,
    parent: Retained<NSView>,
}

// Only touched on the main thread (enforced by callers via run_on_main_thread).
unsafe impl Send for NativePreview {}
unsafe impl Sync for NativePreview {}

impl NativePreview {
    /// # Safety
    /// `webview` must be a valid WKWebView (NSView) pointer; must be called on the main thread.
    pub unsafe fn attach_below_webview(webview: *mut c_void) -> anyhow::Result<Self> {
        let mtm = MainThreadMarker::new().ok_or_else(|| anyhow::anyhow!("not on main thread"))?;
        let wk: &NSView = &*(webview as *const NSView);
        let parent = wk.superview().ok_or_else(|| anyhow::anyhow!("webview has no superview"))?;
        let frame = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(16.0, 16.0));
        let view = NSView::initWithFrame(mtm.alloc(), frame);
        let layer = CAMetalLayer::new();
        layer.setOpaque(true);
        layer.setPresentsWithTransaction(false);
        let scale = wk.window().map(|w| w.backingScaleFactor()).unwrap_or(2.0);
        layer.setContentsScale(scale);
        view.setLayer(Some(&layer));
        view.setWantsLayer(true);
        parent.addSubview_positioned_relativeTo(&view, NSWindowOrderingMode::Below, Some(wk));
        if std::env::var("MONTAGE_DEBUG").is_ok() {
            let subs = parent.subviews();
            let names: Vec<String> = subs.iter().map(|v| v.class().name().to_string_lossy().to_string()).collect();
            let draws: bool = objc2::msg_send![wk, _drawsBackground];
            eprintln!(
                "[present] parent={} flipped={} subviews(bottom->top)={:?} wk.opaque={} wk._drawsBackground={} window.opaque={}",
                parent.class().name().to_string_lossy(),
                parent.isFlipped(),
                names,
                wk.isOpaque(),
                draws,
                wk.window().map(|w| w.isOpaque()).unwrap_or(true)
            );
        }
        Ok(NativePreview { view, layer, parent })
    }

    pub fn layer_ptr(&self) -> *mut c_void {
        Retained::as_ptr(&self.layer) as *mut c_void
    }

    pub fn backing_scale(&self) -> f64 {
        self.view.window().map(|w| w.backingScaleFactor()).unwrap_or(2.0)
    }

    /// Set the frame from web (CSS px, top-left origin) coordinates. Main thread only.
    /// Returns the drawable size in physical pixels.
    pub fn set_frame_css(&self, x: f64, y: f64, w: f64, h: f64) -> (u32, u32) {
        let pb = self.parent.bounds();
        let yy = if self.parent.isFlipped() { y } else { pb.size.height - y - h };
        self.view.setFrame(NSRect::new(NSPoint::new(x, yy), NSSize::new(w, h)));
        let scale = self.backing_scale();
        self.layer.setContentsScale(scale);
        ((w * scale).round() as u32, (h * scale).round() as u32)
    }

    /// # Safety: layer must outlive the surface.
    pub unsafe fn create_surface(&self, instance: &wgpu::Instance) -> anyhow::Result<wgpu::Surface<'static>> {
        Ok(instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(self.layer_ptr()))?)
    }
}
