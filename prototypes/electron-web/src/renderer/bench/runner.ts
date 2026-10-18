// Non-interactive benchmark scenarios (P1–P6 + cold start), selected by --bench=<name>.
import { host, mediaUrl, type HostConfig } from '../host';
import { EngineClient } from '../engine/engineClient';
import { ClipSource } from '../engine/decoder';
import { exportComposition } from '../engine/exporter';
import type { TimelineRenderer } from '../timeline/TimelineCanvas';
import { runSegmentation } from '../ai/seg';
import { decodeAudio, verifyStretchOffline, playStretched } from '../audio/stretch';
import { wer } from './wer';

const CLIPS = ['a.mp4', 'b.mp4', 'c.mp4', 'd.mp4'];
const r1 = (x: number) => Math.round(x * 10) / 10;
const r2 = (x: number) => Math.round(x * 100) / 100;
const raf = () => new Promise<number>((r) => requestAnimationFrame(r));
const pct = (a: number[], p: number) => { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };

export type Ctx = { cfg: HostConfig; playerCanvas: HTMLCanvasElement; timeline: TimelineRenderer; setStatus: (s: string) => void };

export async function runBench(c: Ctx) {
  const a = c.cfg.args;
  const name = c.cfg.bench;
  c.setStatus(name);
  try {
    switch (name) {
      case 'cold': await host.emit('cold_start_ms', Math.round(Date.now() - c.cfg.t0), 'ms', { note: 'process spawn -> UI shell + timeline painted' }); break;
      case 'preview': await benchPreview(c, Number(a.seconds ?? 20)); break;
      case 'scrub': await benchScrub(c, Number(a.count ?? 50)); break;
      case 'export': await benchExport(c, Number(a.seconds ?? 10)); break;
      case 'timeline': await benchTimeline(c, Number(a.seconds ?? 5)); break;
      case 'seg': await benchSeg(Number(a.frames ?? 300), a.backend ?? 'node-cpu'); break;
      case 'stt': await benchStt(); break;
      case 'audio': await benchAudio(c, Number(a.seconds ?? 3)); break;
      default: throw new Error('unknown bench ' + name);
    }
    await host.done(0);
  } catch (e) {
    await host.log('BENCH ERROR', name, (e as Error)?.stack ?? String(e));
    await host.done(2);
  }
}

async function openClips() { return Promise.all(CLIPS.map((n) => ClipSource.open(mediaUrl(n)))); }

async function benchPreview(c: Ctx, seconds: number) {
  const eng = new EngineClient();
  // [bench harness] --layers=8 -> a..d twice (8-layer stress test)
  const n = Number(c.cfg.args.layers ?? 4);
  await eng.init(c.playerCanvas, Array.from({ length: n }, (_, i) => mediaUrl(CLIPS[i % 4])));
  await eng.play(1.0);
  await host.samplerStart();
  await new Promise((r) => setTimeout(r, seconds * 1000));
  if (c.cfg.args.screenshot) await host.log('screenshot', await host.screenshot('preview.png'));
  const st = await eng.stop();
  const s = await host.samplerStop();
  await eng.close();
  await host.emit('preview_fps', r1(st.fresh / st.seconds), 'fps', { slots: st.slots, stale: st.stale, skipped: st.skipped, seconds: r2(st.seconds), engine: 'worker: WebCodecs HEVC HW decode + WebGPU importExternalTexture' });
  await host.emit('preview_dropped_frames', st.dropped, 'frames', { of: st.slots });
  await host.emit('preview_cpu_pct', r1(s.cpuPct), '%', { note: '100% = one core; all Electron processes (main+GPU+renderer+utility)', procs: s.procs });
  await host.emit('preview_rss_mb', Math.round(s.rssMb), 'MB', { peak: Math.round(s.rssPeakMb), procs: s.procs });
}

async function benchScrub(c: Ctx, count: number) {
  const eng = new EngineClient();
  await eng.init(c.playerCanvas, CLIPS.map(mediaUrl));
  const maxT = eng.duration - 1;
  let seed = 42; const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  await eng.seek(0.5);
  const times: number[] = [];
  for (let i = 0; i < count; i++) {
    const t = Math.round(rnd() * maxT * 30) / 30;
    const t0 = performance.now();
    await eng.seek(t); // resolves once all 4 layers are decoded at t and the GPU finished compositing
    times.push(performance.now() - t0);
    await raf();
  }
  await eng.close();
  await host.emit('scrub_ms_p50', r1(pct(times, 50)), 'ms', { n: count });
  await host.emit('scrub_ms_p95', r1(pct(times, 95)), 'ms', { n: count, max: r1(Math.max(...times)) });
}

async function benchExport(c: Ctx, seconds: number) {
  const t0 = performance.now();
  const sources = await openClips();
  const res = await exportComposition(sources, seconds, 'export.mp4');
  const dt = (performance.now() - t0) / 1000;
  const probe = JSON.parse(await host.probe(res.path));
  const v = probe.streams?.[0] ?? {};
  await host.emit('export_seconds', r2(dt), 's', { duration_s: seconds, frames: res.frames, codec: v.codec_name, w: v.width, h: v.height, nb_frames: v.nb_frames, encoder: 'WebCodecs VideoEncoder avc1 prefer-hardware', path: res.path });
}

async function benchTimeline(c: Ctx, seconds: number) {
  const tl = c.timeline;
  const v = tl.view;
  const start = { px: v.pxPerSec, sx: v.scrollX };
  const frameTimes: number[] = []; const drawMs: number[] = [];
  let last = await raf(); const t0 = last; let maxDrawn = 0;
  for (;;) {
    const now = await raf();
    const e = (now - t0) / 1000;
    if (e >= seconds) break;
    // zoom oscillates 4..400 px/s (≈ whole timeline -> 0.25 s frames), scroll sweeps across the project
    v.pxPerSec = 4 * Math.pow(100, 0.5 - 0.5 * Math.cos(e * Math.PI * 0.8));
    v.scrollX = Math.max(0, (tl.model.duration * v.pxPerSec - (tl.w - 120)) * (0.5 - 0.5 * Math.cos(e * 1.3)));
    v.playhead = e * 10;
    const d0 = performance.now(); tl.draw(); maxDrawn = Math.max(maxDrawn, tl.drawnClips);
    drawMs.push(performance.now() - d0); frameTimes.push(now - last); last = now;
  }
  const fps = frameTimes.length / seconds;
  v.pxPerSec = start.px; v.scrollX = start.sx; tl.draw();
  const clipCount = tl.model.clips.reduce((n, a) => n + a.length, 0);
  await host.emit('timeline_fps', r1(fps), 'fps', { clips: clipCount, tracks: tl.model.tracks.length, p95_frame_ms: r1(pct(frameTimes, 95)), max_visible_clips: maxDrawn, avg_draw_ms: r2(drawMs.reduce((a, b) => a + b, 0) / drawMs.length), p95_draw_ms: r2(pct(drawMs, 95)), dpr: window.devicePixelRatio, display_hz_note: 'rAF-bound; display refresh caps fps' });
}

async function benchSeg(frames: number, backend: string) {
  const src = await ClipSource.open(mediaUrl('h264_1080.mp4'));
  const r = await runSegmentation(src, frames, backend);
  await host.emit('seg_fps', r1(r.fps), 'fps', { frames: r.frames, model: 'RVM mobilenetv3 fp32 (ONNX, 14.3 MB)', input: '960x544, downsample 0.25', backend: r.backend, load_ms: Math.round(r.loadMs), avg_infer_ms: r1(r.avgInferMs), pipeline: 'WebCodecs decode -> GPU downscale -> readback -> ORT' });
}

async function benchStt() {
  const ref = await (await fetch('media://bench/speech_fr.txt')).text().catch(() => '');
  const { wallMs, audioSec, json } = await host.stt('speech_fr.wav');
  // Words with timestamps from token-level output (DTW-aligned).
  const words: { w: string; t0: number; t1: number }[] = [];
  for (const seg of json.transcription ?? []) for (const tok of seg.tokens ?? []) {
    const txt: string = tok.text; if (txt.startsWith('[_')) continue;
    if (txt.startsWith(' ') || words.length === 0) words.push({ w: txt.trim(), t0: tok.offsets.from, t1: tok.offsets.to });
    else { const lw = words[words.length - 1]; lw.w += txt; lw.t1 = tok.offsets.to; }
  }
  const hyp = (json.transcription ?? []).map((s: any) => s.text).join(' ');
  await host.emit('stt_rtf', r2((wallMs / 1000) / audioSec), 'x', { wall_ms: Math.round(wallMs), engine: 'whisper.cpp large-v3-turbo q5_0 (Metal) sidecar', includes_model_load: true, audio_s: r1(audioSec), words: words.length, first_words: words.slice(0, 4) });
  if (ref) await host.emit('stt_wer_estimate', r2(wer(ref, hyp)), 'ratio', { hyp: hyp.slice(0, 200) });
}

async function benchAudio(c: Ctx, seconds: number) {
  const { channels, sampleRate } = await decodeAudio(mediaUrl('a.mp4'), 12);
  const off = await verifyStretchOffline(channels, sampleRate, 1.5);
  // Real-time: 1.5x audio while the video layer plays at 1.5x.
  const eng = new EngineClient();
  await eng.init(c.playerCanvas, [mediaUrl('a.mp4')]);
  const actx = new AudioContext({ sampleRate, latencyHint: 'playback' });
  await actx.resume();
  const node = await playStretched(actx, channels, 1.5);
  await eng.play(0, 1.5);
  const ctx0 = actx.currentTime, in0 = node.inputTime;
  await new Promise((r) => setTimeout(r, seconds * 1000));
  const rtRate = (node.inputTime - in0) / (actx.currentTime - ctx0);
  const st = await eng.stop(); await eng.close();
  node.stop(); await actx.close();
  const ok = off.ok && Math.abs(rtRate - 1.5) < 0.1 && actx.state === 'closed';
  await host.emit('audio_stretch_ok', ok, 'bool', { rate: 1.5, in_hz: r1(off.inFreq), out_hz: r1(off.outFreq), realtime_input_rate: r2(rtRate), video_fps_during: r1(st.fresh / st.seconds), api: 'Signalsmith Stretch WASM AudioWorklet (signalsmith-stretch npm)' });
}
