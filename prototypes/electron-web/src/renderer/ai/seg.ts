// Person segmentation (Robust Video Matting, recurrent) over decoded video frames.
// Backends:
//   node-cpu / node-coreml: onnxruntime-node in an Electron utilityProcess (MessagePort, RGBA frames in, alpha out)
//   web-webgpu: onnxruntime-web (JSEP/WebGPU) inside the renderer
// Frames are decoded with WebCodecs and downscaled on the GPU (canvas drawImage) before readback.
import { ClipSource, LayerDecoder } from '../engine/decoder';
import { host } from '../host';

export type SegResult = { frames: number; seconds: number; fps: number; loadMs: number; avgInferMs: number; avgCoverage: number; backend: string };

export async function runSegmentation(src: ClipSource, nFrames: number, backend: string, W = 960, H = 544, ds = 0.25): Promise<SegResult> {
  const canvas = new OffscreenCanvas(W, H);
  const ctx = canvas.getContext('2d', { willReadFrequently: false })!;
  const dec = new LayerDecoder(src, 6);
  await dec.startAt(0);
  const grab = async (i: number) => {
    const f = await dec.waitFrame(i / 30);
    ctx.drawImage(f!, 0, 0, W, H);
    return ctx.getImageData(0, 0, W, H).data;
  };

  let infer: (rgba: Uint8ClampedArray, id: number) => Promise<{ coverage: number; inferMs: number }>;
  let loadMs = 0;
  const tLoad = performance.now();
  if (backend.startsWith('node')) {
    const portP = new Promise<MessagePort>((res) => {
      const h = (e: MessageEvent) => { if (e.data === 'seg:port') { window.removeEventListener('message', h); res(e.ports[0]); } };
      window.addEventListener('message', h);
    });
    await host.segConnect({ ep: backend === 'node-coreml' ? 'coreml' : 'cpu', width: W, height: H, downsample: ds });
    const port = await portP;
    const pending = new Map<number, (v: { coverage: number; inferMs: number }) => void>();
    await new Promise<void>((res) => {
      port.onmessage = (e) => {
        const d = e.data;
        if (d.type === 'ready') { loadMs = d.loadMs; res(); }
        if (d.type === 'matte') { pending.get(d.id)!({ coverage: d.coverage, inferMs: d.inferMs }); pending.delete(d.id); }
      };
      port.start();
    });
    infer = (rgba, id) => new Promise((res) => { pending.set(id, res); port.postMessage({ type: 'frame', id, rgba: new Uint8Array(rgba.buffer) }); });
    // (Electron renderer<->utility ports: structured clone copy; ArrayBuffer transfer is unsupported.)
  } else {
    const ort = await import('onnxruntime-web/webgpu');
    ort.env.wasm.numThreads = 1;
    ort.env.logLevel = 'error';
    const buf = await (await fetch('media://models/rvm_mobilenetv3_fp32.onnx')).arrayBuffer();
    const session = await ort.InferenceSession.create(buf, { executionProviders: ['webgpu'], graphOptimizationLevel: 'all' });
    loadMs = performance.now() - tLoad;
    const z = () => new ort.Tensor('float32', new Float32Array(1), [1, 1, 1, 1]);
    let rec: Record<string, any> = { r1i: z(), r2i: z(), r3i: z(), r4i: z() };
    const chw = new Float32Array(3 * W * H);
    const dsT = new ort.Tensor('float32', new Float32Array([ds]), [1]);
    infer = async (rgba) => {
      const t1 = performance.now(); const n = W * H;
      for (let i = 0, j = 0; i < n; i++, j += 4) { chw[i] = rgba[j] / 255; chw[i + n] = rgba[j + 1] / 255; chw[i + 2 * n] = rgba[j + 2] / 255; }
      const out = await session.run({ src: new ort.Tensor('float32', chw, [1, 3, H, W]), ...rec, downsample_ratio: dsT });
      rec = { r1i: out.r1o, r2i: out.r2o, r3i: out.r3o, r4i: out.r4o };
      const pha = out.pha.data as Float32Array; let cov = 0;
      for (let i = 0; i < pha.length; i += 16) cov += pha[i];
      return { coverage: cov / (pha.length / 16), inferMs: performance.now() - t1 };
    };
  }
  // warm-up frame (first inference compiles kernels / CoreML model); not counted
  await infer(await grab(0), -1);
  const t0 = performance.now();
  let inferSum = 0, covSum = 0;
  // Pipeline: decode+downscale frame i+1 while frame i is inferred.
  let next = grab(1);
  for (let i = 1; i <= nFrames; i++) {
    const rgba = await next;
    const p = infer(rgba, i);
    if (i < nFrames) next = grab(i + 1);
    const r = await p; inferSum += r.inferMs; covSum += r.coverage;
  }
  const seconds = (performance.now() - t0) / 1000;
  dec.close();
  return { frames: nFrames, seconds, fps: nFrames / seconds, loadMs, avgInferMs: inferSum / nFrames, avgCoverage: covSum / nFrames, backend };
}
