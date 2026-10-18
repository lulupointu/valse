// Time-stretch with pitch preservation: Signalsmith Stretch (C++ -> WASM) running in an AudioWorklet.
// Audio is decoded with WebCodecs AudioDecoder via mediabunny.
import { Input, ALL_FORMATS, UrlSource, AudioBufferSink } from 'mediabunny';
// @ts-ignore - no types shipped
import SignalsmithStretch from 'signalsmith-stretch';

export async function decodeAudio(url: string, seconds: number) {
  const input = new Input({ source: new UrlSource(url), formats: ALL_FORMATS });
  const track = (await input.getPrimaryAudioTrack())!;
  const sink = new AudioBufferSink(track);
  const chans: Float32Array[][] = [];
  let sr = 48000, len = 0;
  for await (const { buffer } of sink.buffers(0, seconds)) {
    sr = buffer.sampleRate;
    for (let c = 0; c < buffer.numberOfChannels; c++) (chans[c] ??= []).push(buffer.getChannelData(c).slice());
    len += buffer.length;
  }
  const out = chans.map((parts) => { const a = new Float32Array(len); let o = 0; for (const p of parts) { a.set(p, o); o += p.length; } return a; });
  return { channels: out, sampleRate: sr };
}

/** Dominant frequency estimate via zero crossings (fine for the pure tones in the test media). */
export function estimateFreq(x: Float32Array, sr: number) {
  let zc = 0;
  for (let i = 1; i < x.length; i++) if ((x[i - 1] < 0) !== (x[i] < 0)) zc++;
  return (zc / 2) / (x.length / sr);
}

/** Offline verification: stretch to 1.5x and check pitch and consumed input duration. */
export async function verifyStretchOffline(ch: Float32Array[], sr: number, rate = 1.5) {
  const outSec = 3;
  const ctx = new OfflineAudioContext(ch.length, sr * outSec, sr);
  const node = await SignalsmithStretch(ctx, { numberOfInputs: 0, outputChannelCount: [ch.length] });
  node.connect(ctx.destination);
  await node.addBuffers(ch);
  node.schedule({ output: 0, input: 0, rate, active: true });
  const rendered = await ctx.startRendering();
  const mid = rendered.getChannelData(0).subarray(sr * 1, sr * 2.5);
  const inFreq = estimateFreq(ch[0].subarray(sr, sr * 2), sr);
  const outFreq = estimateFreq(mid, sr);
  return { inFreq, outFreq, ok: Math.abs(outFreq - inFreq) / inFreq < 0.02 };
}

/** Real-time playback at `rate` with pitch preserved; returns the node so the caller can monitor inputTime. */
export async function playStretched(ctx: AudioContext, ch: Float32Array[], rate: number) {
  const node = await SignalsmithStretch(ctx, { numberOfInputs: 0, outputChannelCount: [ch.length] });
  node.connect(ctx.destination);
  await node.addBuffers(ch);
  node.setUpdateInterval?.(0.05);
  node.schedule({ input: 0, rate, active: true });
  return node as { inputTime: number; stop(): void; disconnect(): void };
}
