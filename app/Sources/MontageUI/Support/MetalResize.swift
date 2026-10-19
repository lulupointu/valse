import QuartzCore
@preconcurrency import Metal

/// Flicker-free resizing of the app's CAMetalLayer views (timeline, player) — C3b.
///
/// Root cause of the flicker on splitter drags / window resizes: `layout()` changed `drawableSize` but the next frame
/// was only drawn on the following display-link tick and presented asynchronously, outside the Core Animation
/// transaction that applied the new view geometry. For a frame or more the window showed the previous drawable
/// stretched to the new bounds (or an empty layer), then snapped back. During a resize we now draw synchronously in
/// `layout()` with `presentsWithTransaction`, so the frame and the geometry land in the same transaction.
enum MetalResize {
    /// Runs `draw` with `presentsWithTransaction` on, implicit layer animations off.
    @MainActor static func synchronously(_ layer: CAMetalLayer, _ draw: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.presentsWithTransaction = true
        draw()
        layer.presentsWithTransaction = false
        CATransaction.commit()
        presentedInTransaction += 1
    }

    /// Commits `cmd` and presents `drawable` the way the layer wants (in the current CA transaction while resizing).
    static func present(_ drawable: CAMetalDrawable, _ cmd: MTLCommandBuffer, on layer: CAMetalLayer) {
        if layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
    }

    /// Frames presented synchronously during layout (tests).
    @MainActor static var presentedInTransaction = 0
}
