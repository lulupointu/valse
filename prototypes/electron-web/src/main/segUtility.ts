// Electron utilityProcess: Robust Video Matting via onnxruntime-node (CPU or CoreML EP).
// Receives RGBA frames (already downscaled on the GPU by the renderer), returns an 8-bit alpha matte.
import * as ort from 'onnxruntime-node';

type Init = { type: 'init'; model: string; ep: string; width: number; height: number; downsample: number };
let session: ort.InferenceSession;
let rec: Record<string, ort.Tensor> = {};
let W = 0, H = 0, ds = 0.25;
let chw: Float32Array;

process.parentPort.on('message', async (e: Electron.MessageEvent) => {
  const msg = e.data as Init;
  if (!msg || msg.type !== 'init') return;
  const port = e.ports[0];
  W = msg.width; H = msg.height; ds = msg.downsample;
  const eps: ort.InferenceSession.SessionOptions['executionProviders'] =
    msg.ep === 'coreml' ? [{ name: 'coreml', modelFormat: 'MLProgram', computeUnits: 'ALL' } as any] : ['cpu'];
  const t0 = performance.now();
  session = await ort.InferenceSession.create(msg.model, { executionProviders: eps, logSeverityLevel: 3, graphOptimizationLevel: 'all' });
  chw = new Float32Array(3 * W * H);
  resetState();
  port.on('message', async (m: Electron.MessageEvent) => {
    const d = m.data as { type: string; id: number; rgba?: Uint8Array };
    if (!d) return;
    if (d.type === 'reset') { resetState(); return; }
    if (d.type !== 'frame') return;
    const t1 = performance.now();
    const rgba = d.rgba!;
    const n = W * H;
    for (let i = 0, j = 0; i < n; i++, j += 4) { chw[i] = rgba[j] / 255; chw[i + n] = rgba[j + 1] / 255; chw[i + 2 * n] = rgba[j + 2] / 255; }
    const feeds: Record<string, ort.Tensor> = {
      src: new ort.Tensor('float32', chw, [1, 3, H, W]), ...rec,
      downsample_ratio: new ort.Tensor('float32', new Float32Array([ds]), [1]),
    };
    const out = await session.run(feeds);
    rec = { r1i: out.r1o, r2i: out.r2o, r3i: out.r3o, r4i: out.r4o };
    const pha = out.pha.data as Float32Array;
    const alpha = new Uint8Array(n);
    let cover = 0;
    for (let i = 0; i < n; i++) { const a = pha[i]; alpha[i] = a * 255; cover += a; }
    port.postMessage({ type: 'matte', id: d.id, alpha, coverage: cover / n, inferMs: performance.now() - t1 });
  });
  port.start();
  port.postMessage({ type: 'ready', loadMs: performance.now() - t0 });
});

function resetState() {
  const z = () => new ort.Tensor('float32', new Float32Array(1), [1, 1, 1, 1]);
  rec = { r1i: z(), r2i: z(), r3i: z(), r4i: z() };
}
