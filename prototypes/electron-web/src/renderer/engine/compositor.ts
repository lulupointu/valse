// WebGPU compositor. Each layer: VideoFrame -> importExternalTexture (zero-copy IOSurface on macOS),
// affine transform, opacity, color adjustments (brightness/saturation) and alpha blending.
// The same class renders to the on-screen canvas (preview) or an OffscreenCanvas (export).

export type LayerParams = {
  x: number; y: number;          // center, in output pixels
  scale: number; rotation: number; // rotation in radians
  opacity: number; brightness: number; saturation: number;
};

const WGSL = /* wgsl */ `
struct U { m0: vec4f, m1: vec4f, color: vec4f };  // m0/m1: 2x3 affine (clip space); color: opacity, brightness, saturation
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_external;
@group(0) @binding(2) var<uniform> u: U;
struct VO { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
@vertex fn vs(@builtin(vertex_index) i: u32) -> VO {
  var q = array<vec2f, 4>(vec2f(-1., -1.), vec2f(1., -1.), vec2f(-1., 1.), vec2f(1., 1.));
  let p = q[i];
  var o: VO;
  let x = u.m0.x * p.x + u.m0.y * p.y + u.m0.z;
  let y = u.m1.x * p.x + u.m1.y * p.y + u.m1.z;
  o.pos = vec4f(x, y, 0., 1.);
  o.uv = vec2f(p.x * .5 + .5, .5 - p.y * .5);
  return o;
}
@fragment fn fs(v: VO) -> @location(0) vec4f {
  var c = textureSampleBaseClampToEdge(tex, samp, v.uv).rgb;
  c = c + vec3f(u.color.y);
  let l = dot(c, vec3f(.2126, .7152, .0722));
  c = mix(vec3f(l), c, u.color.z);
  let a = u.color.x;
  return vec4f(clamp(c, vec3f(0.), vec3f(1.)) * a, a);   // premultiplied
}`;

export class Compositor {
  device!: GPUDevice; ctx!: GPUCanvasContext; pipeline!: GPURenderPipeline; sampler!: GPUSampler;
  private ubufs: GPUBuffer[] = [];
  format: GPUTextureFormat = 'bgra8unorm';
  constructor(public canvas: HTMLCanvasElement | OffscreenCanvas, public W: number, public H: number) {}

  static async create(canvas: HTMLCanvasElement | OffscreenCanvas, W: number, H: number, device?: GPUDevice) {
    const c = new Compositor(canvas, W, H);
    if (!device) {
      const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
      if (!adapter) throw new Error('WebGPU unavailable');
      device = await adapter.requestDevice();
    }
    c.device = device;
    canvas.width = W; canvas.height = H;
    c.ctx = canvas.getContext('webgpu') as GPUCanvasContext;
    c.format = navigator.gpu.getPreferredCanvasFormat();
    c.ctx.configure({ device, format: c.format, alphaMode: 'opaque' });
    const mod = device.createShaderModule({ code: WGSL });
    c.pipeline = device.createRenderPipeline({
      layout: 'auto',
      vertex: { module: mod, entryPoint: 'vs' },
      fragment: { module: mod, entryPoint: 'fs', targets: [{ format: c.format, blend: {
        color: { srcFactor: 'one', dstFactor: 'one-minus-src-alpha', operation: 'add' },
        alpha: { srcFactor: 'one', dstFactor: 'one-minus-src-alpha', operation: 'add' } } }] },
      primitive: { topology: 'triangle-strip' },
    });
    c.sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });
    return c;
  }

  private ubuf(i: number) {
    while (this.ubufs.length <= i) this.ubufs.push(this.device.createBuffer({ size: 48, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST }));
    return this.ubufs[i];
  }

  /** Composite layers (bottom first). Frames may be null (layer skipped). */
  render(layers: { frame: VideoFrame | null; p: LayerParams }[]) {
    const d = this.device;
    const enc = d.createCommandEncoder();
    const pass = enc.beginRenderPass({ colorAttachments: [{ view: this.ctx.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store', clearValue: { r: 0.05, g: 0.05, b: 0.06, a: 1 } }] });
    pass.setPipeline(this.pipeline);
    layers.forEach(({ frame, p }, i) => {
      if (!frame) return;
      const fw = frame.displayWidth, fh = frame.displayHeight;
      // Quad [-1,1]^2 (y up) -> layer rect of half-size (sx, sy) px, rotated, centered at (x, y) px (y down) -> clip.
      const sx = (fw * p.scale) / 2, sy = (fh * p.scale) / 2;
      const c = Math.cos(p.rotation), s = Math.sin(p.rotation);
      const kx = 2 / this.W, ky = 2 / this.H;
      const u = new Float32Array([
        kx * c * sx, kx * s * sy, p.x * kx - 1, 0,
        -ky * s * sx, ky * c * sy, 1 - p.y * ky, 0,
        p.opacity, p.brightness, p.saturation, 0]);
      d.queue.writeBuffer(this.ubuf(i), 0, u);
      const bg = d.createBindGroup({ layout: this.pipeline.getBindGroupLayout(0), entries: [
        { binding: 0, resource: this.sampler },
        { binding: 1, resource: d.importExternalTexture({ source: frame }) },
        { binding: 2, resource: { buffer: this.ubuf(i) } }] });
      pass.setBindGroup(0, bg);
      pass.draw(4);
    });
    pass.end();
    d.queue.submit([enc.finish()]);
  }
}

/** The P1 composition: 4 overlapping 4K layers with distinct transforms, opacity 0.8, color filter. */
export function benchLayout(W: number, H: number, t: number): LayerParams[] {
  const base = 1 / 3.2; // 3840 * 0.3125 = 1200 px wide
  const L: LayerParams[] = [
    { x: W * 0.32, y: H * 0.33, scale: base, rotation: 0, opacity: 0.8, brightness: 0.05, saturation: 1.4 },
    { x: W * 0.68, y: H * 0.35, scale: base * 0.9, rotation: 0.05 * Math.sin(t), opacity: 0.8, brightness: -0.05, saturation: 0.6 },
    { x: W * 0.35, y: H * 0.68, scale: base * 0.85, rotation: -0.08, opacity: 0.8, brightness: 0.0, saturation: 1.8 },
    { x: W * 0.62 + 40 * Math.sin(t * 2), y: H * 0.62, scale: base * 1.1, rotation: 0.1, opacity: 0.8, brightness: 0.1, saturation: 0.3 },
  ];
  // [bench harness] layers 5-8 for the 8-layer stress test (same clips again, smaller, offset). Callers index
  // by decoder, so 4-layer runs only use the first 4.
  for (let i = 0; i < 4; i++) L.push({ ...L[i], scale: L[i].scale * 0.6, x: W * (0.2 + 0.6 * (i % 2)), y: H * (0.25 + 0.5 * Math.floor(i / 2)) });
  return L;
}
