// Playback engine: wall clock -> media time, per-layer decoders, composite once per new 30 fps frame slot.
import { Compositor, benchLayout } from './compositor';
import { ClipSource, LayerDecoder } from './decoder';

export type PlayStats = { slots: number; fresh: number; dropped: number; seconds: number; stale: number; skipped: number };

export class Player {
  decoders: LayerDecoder[];
  playing = false; rate = 1; fps = 30;
  private startWall = 0; private startMedia = 0; private lastSlot = -1; private raf = 0;
  stats: PlayStats = { slots: 0, fresh: 0, dropped: 0, seconds: 0, stale: 0, skipped: 0 };
  onFrame?: (t: number) => void;

  constructor(public comp: Compositor, public sources: ClipSource[]) {
    this.decoders = sources.map((s) => new LayerDecoder(s, 5));
  }

  get duration() { return Math.min(...this.sources.map((s) => s.duration)); }

  mediaTime(now = performance.now()) { return this.startMedia + ((now - this.startWall) / 1000) * this.rate; }

  /** Seek: decode all layers to t and show the composited frame. Resolves after the frame is submitted to the GPU. */
  async seek(t: number) {
    const a = performance.now();
    await Promise.all(this.decoders.map((d) => d.startAt(t)));
    const b = performance.now();
    const frames = await Promise.all(this.decoders.map((d) => d.waitFrame(t)));
    if ((globalThis as any).DEBUG_SEEK) console.log(`seek ${t.toFixed(2)} start=${(b - a).toFixed(1)} decode=${(performance.now() - b).toFixed(1)}`);
    this.comp.render(frames.map((frame, i) => ({ frame, p: benchLayout(this.comp.W, this.comp.H, t)[i] })));
    this.startMedia = t;
    return frames;
  }

  async play(from: number, rate = 1) {
    this.rate = rate;
    await this.seek(from);
    // Prime: let each decoder fill its queue before starting the clock (like a real player's preroll).
    await Promise.all(this.decoders.map((d) => d.waitFrame(from + 3 / this.fps)));
    this.stats = { slots: 0, fresh: 0, dropped: 0, seconds: 0, stale: 0, skipped: 0 };
    this.playing = true; this.startWall = performance.now(); this.startMedia = from; this.lastSlot = Math.floor(from * this.fps + 1e-6);
    const loop = (now: number) => {
      if (!this.playing) return;
      this.raf = requestAnimationFrame(loop);
      this.tick(now);
    };
    this.raf = requestAnimationFrame(loop);
  }

  private tick(now: number) {
    const t = this.mediaTime(now);
    const slot = Math.floor(t * this.fps + 1e-6);
    if (slot === this.lastSlot) return;
    const gap = slot - this.lastSlot;
    if (gap > 1) { this.stats.skipped += gap - 1; this.stats.dropped += gap - 1; this.stats.slots += gap - 1; }
    this.lastSlot = slot;
    this.stats.slots++;
    const layout = benchLayout(this.comp.W, this.comp.H, t);
    let allFresh = true;
    const layers = this.decoders.map((d, i) => {
      const f = d.frameAt(t);
      if (!f || Math.round((f.timestamp / 1e6) * this.fps) !== slot) allFresh = false;
      return { frame: f, p: layout[i] };
    });
    this.comp.render(layers);
    if (allFresh) this.stats.fresh++; else { this.stats.stale++; this.stats.dropped++; }
    this.onFrame?.(t);
  }

  stop() {
    this.playing = false; cancelAnimationFrame(this.raf);
    this.stats.seconds = (performance.now() - this.startWall) / 1000;
    return this.stats;
  }

  close() { this.stop(); this.decoders.forEach((d) => d.close()); }
}
