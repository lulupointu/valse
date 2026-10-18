// Export: same compositor on an OffscreenCanvas -> VideoFrame -> hardware H.264 VideoEncoder -> mediabunny MP4 muxer,
// streamed to disk through the main process (no full-file buffering).
import { Output, Mp4OutputFormat, StreamTarget, EncodedVideoPacketSource, EncodedPacket } from 'mediabunny';
import { Compositor, benchLayout } from './compositor';
import { ClipSource, LayerDecoder } from './decoder';
import { host } from '../host';

export async function exportComposition(sources: ClipSource[], seconds: number, fileName: string, device?: GPUDevice,
  onProgress?: (p: number) => void) {
  const W = 1920, H = 1080, FPS = 30;
  const canvas = new OffscreenCanvas(W, H);
  const comp = await Compositor.create(canvas, W, H, device);
  const decoders = sources.map((s) => new LayerDecoder(s, 6));
  await Promise.all(decoders.map((d) => d.startAt(0)));

  const file = await host.fileOpen(fileName);
  const writes: Promise<void>[] = [];
  const target = new StreamTarget(new WritableStream({
    write: (chunk: { type: 'write'; data: Uint8Array; position: number }) => { writes.push(host.fileWrite(file.id, chunk.data, chunk.position)); },
  }), { chunked: true, chunkSize: 4 << 20 });
  const output = new Output({ format: new Mp4OutputFormat({ fastStart: false }), target });
  const vsrc = new EncodedVideoPacketSource('avc');
  output.addVideoTrack(vsrc, { frameRate: FPS });
  await output.start();

  const cfg: VideoEncoderConfig = { codec: 'avc1.640028', width: W, height: H, bitrate: 12_000_000, framerate: FPS,
    hardwareAcceleration: 'prefer-hardware', latencyMode: 'quality', avc: { format: 'avc' } };
  const support = await VideoEncoder.isConfigSupported(cfg);
  if (!support.supported) throw new Error('H.264 encoder config unsupported');
  let muxChain = Promise.resolve();
  let encErr: unknown = null;
  const encoder = new VideoEncoder({
    output: (chunk, meta) => { const pkt = EncodedPacket.fromEncodedChunk(chunk); muxChain = muxChain.then(() => vsrc.add(pkt, meta)); },
    error: (e) => { encErr = e; },
  });
  encoder.configure(cfg);
  let hwInfo = 'prefer-hardware';
  const total = Math.round(seconds * FPS);
  for (let i = 0; i < total; i++) {
    const t = i / FPS;
    const frames = await Promise.all(decoders.map((d) => d.waitFrame(t)));
    const layout = benchLayout(W, H, t);
    comp.render(frames.map((frame, k) => ({ frame, p: layout[k] })));
    const vf = new VideoFrame(canvas, { timestamp: Math.round(t * 1e6), duration: Math.round(1e6 / FPS) });
    while (encoder.encodeQueueSize > 4) await new Promise((r) => setTimeout(r, 1));
    encoder.encode(vf, { keyFrame: i % 60 === 0 });
    vf.close();
    if (encErr) throw encErr;
    onProgress?.((i + 1) / total);
  }
  await encoder.flush();
  encoder.close();
  await muxChain;
  await output.finalize();
  await Promise.all(writes);
  await host.fileClose(file.id);
  decoders.forEach((d) => d.close());
  return { path: file.path as string, frames: total, hwInfo };
}
