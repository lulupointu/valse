// Canvas timeline with virtualization: only clips intersecting the viewport are drawn
// (binary search per track over clips sorted by start). One <canvas>, no DOM per clip.
import { t } from "./i18n";

export interface Clip { id: number; track: number; start: number; dur: number; color: string; label: string }

const TRACK_H = 36;
const HEADER_W = 90;
const RULER_H = 22;
const COLORS = ["#2f7fd1", "#3aa57a", "#c7802a", "#8b55d6", "#2aa7b3", "#c24f6a"];

export function makeClips(n: number, tracks: number): Clip[] {
  const clips: Clip[] = [];
  const cursor = new Array(tracks).fill(0);
  let seed = 12345;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  for (let i = 0; i < n; i++) {
    const track = i % tracks;
    const gap = rnd() < 0.3 ? rnd() * 2 : 0;
    const dur = 1 + rnd() * 6;
    const start = cursor[track] + gap;
    cursor[track] = start + dur;
    clips.push({ id: i, track, start, dur, color: COLORS[track % COLORS.length], label: t("clip.label", { n: i + 1 }) });
  }
  return clips;
}

export class Timeline {
  ctx: CanvasRenderingContext2D;
  byTrack: Clip[][] = [];
  pxPerSec = 40;
  scrollX = 0; // seconds at left edge
  playhead = 0;
  width = 0; height = 0; dpr = 1;
  totalDur = 0;
  drawnClips = 0;

  constructor(public canvas: HTMLCanvasElement, clips: Clip[], public tracks: number) {
    this.ctx = canvas.getContext("2d", { alpha: false })!;
    for (let i = 0; i < tracks; i++) this.byTrack.push([]);
    for (const c of clips) this.byTrack[c.track].push(c);
    for (const tr of this.byTrack) tr.sort((a, b) => a.start - b.start);
    this.totalDur = Math.max(...clips.map((c) => c.start + c.dur));
    new ResizeObserver(() => this.resize()).observe(canvas);
    this.resize();
    this.installInteraction();
  }

  resize() {
    this.dpr = window.devicePixelRatio || 1;
    const r = this.canvas.getBoundingClientRect();
    this.width = r.width; this.height = r.height;
    this.canvas.width = Math.round(r.width * this.dpr);
    this.canvas.height = Math.round(r.height * this.dpr);
    this.draw();
  }

  installInteraction() {
    this.canvas.addEventListener("wheel", (e) => {
      e.preventDefault();
      if (e.ctrlKey || e.metaKey) {
        const mouseT = this.scrollX + (e.offsetX - HEADER_W) / this.pxPerSec;
        this.pxPerSec = Math.min(400, Math.max(2, this.pxPerSec * Math.exp(-e.deltaY * 0.01)));
        this.scrollX = Math.max(0, mouseT - (e.offsetX - HEADER_W) / this.pxPerSec);
      } else {
        this.scrollX = Math.max(0, this.scrollX + (e.deltaX || e.deltaY) / this.pxPerSec);
      }
      this.draw();
    }, { passive: false });
  }

  firstVisible(track: Clip[], t0: number): number {
    let lo = 0, hi = track.length;
    while (lo < hi) { const m = (lo + hi) >> 1; if (track[m].start + track[m].dur < t0) lo = m + 1; else hi = m; }
    return lo;
  }

  draw() {
    const { ctx, dpr, width: w, height: h } = this;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = "#141417"; ctx.fillRect(0, 0, w, h);
    const t0 = this.scrollX, t1 = this.scrollX + (w - HEADER_W) / this.pxPerSec;
    const x = (tt: number) => HEADER_W + (tt - t0) * this.pxPerSec;
    // ruler
    ctx.fillStyle = "#1d1d22"; ctx.fillRect(0, 0, w, RULER_H);
    const step = [0.1, 0.5, 1, 2, 5, 10, 30, 60, 120].find((s) => s * this.pxPerSec > 60) ?? 300;
    ctx.strokeStyle = "#3a3a44"; ctx.fillStyle = "#8a8a96"; ctx.font = "10px -apple-system"; ctx.beginPath();
    for (let s = Math.floor(t0 / step) * step; s < t1; s += step) {
      const px = Math.round(x(s)) + 0.5; ctx.moveTo(px, RULER_H - 8); ctx.lineTo(px, RULER_H);
      const mm = Math.floor(s / 60), ss = Math.floor(s % 60);
      ctx.fillText(`${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")}`, px + 3, 11);
    }
    ctx.stroke();
    // tracks
    let drawn = 0;
    ctx.font = "11px -apple-system";
    for (let ti = 0; ti < this.tracks; ti++) {
      const y = RULER_H + 4 + ti * (TRACK_H + 4);
      if (y > h) break;
      const track = this.byTrack[ti];
      for (let i = this.firstVisible(track, t0); i < track.length && track[i].start < t1; i++) {
        const c = track[i];
        const cx = x(c.start), cw = Math.max(1, c.dur * this.pxPerSec - 1);
        const left = Math.max(cx, HEADER_W), right = Math.min(cx + cw, w);
        if (right <= left) continue;
        ctx.fillStyle = c.color;
        ctx.beginPath(); ctx.roundRect(cx, y, cw, TRACK_H, 4); ctx.fill();
        if (cw > 30) {
          // thumbnail placeholder (filmstrip cell)
          ctx.fillStyle = "rgba(0,0,0,0.28)"; ctx.fillRect(cx + 2, y + 2, Math.min(52, cw - 4), TRACK_H - 4);
        }
        if (cw > 70) {
          ctx.save(); ctx.beginPath(); ctx.rect(left, y, right - left, TRACK_H); ctx.clip();
          ctx.fillStyle = "#fff"; ctx.fillText(c.label, Math.max(cx + 58, HEADER_W + 4), y + 15);
          ctx.restore();
        }
        drawn++;
      }
      // header
      ctx.fillStyle = "#1d1d22"; ctx.fillRect(0, y, HEADER_W - 2, TRACK_H);
      ctx.fillStyle = "#8a8a96"; ctx.fillText(`V${ti + 1}`, 10, y + 24);
    }
    // playhead
    const px = x(this.playhead);
    if (px >= HEADER_W) { ctx.fillStyle = "#00c1cd"; ctx.fillRect(Math.round(px), 0, 1.5, h); }
    this.drawnClips = drawn;
  }
}
