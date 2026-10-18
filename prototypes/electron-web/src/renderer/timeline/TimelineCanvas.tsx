// Virtualized, canvas-drawn timeline. Only clips intersecting the viewport are drawn (binary search per track).
// One <canvas>, no DOM per clip. Rendering is driven by rAF when the view changes.
import { useEffect, useRef } from 'react';
import { t as tr } from '../i18n';

export type Clip = { id: number; track: number; start: number; dur: number; label: string; hue: number };
export type TimelineModel = { tracks: { name: string; kind: 'video' | 'audio' | 'text' | 'effect' }[]; clips: Clip[][]; duration: number };

export function makeTimeline(nClips = 500, nTracks = 6, seed = 7): TimelineModel {
  let s = seed; const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const kinds = ['text', 'effect', 'video', 'video', 'video', 'audio'] as const;
  const tracks = Array.from({ length: nTracks }, (_, i) => ({ name: `${kinds[i % kinds.length]} ${i + 1}`, kind: kinds[i % kinds.length] }));
  const clips: Clip[][] = tracks.map(() => []);
  const per = Math.ceil(nClips / nTracks);
  let id = 0, duration = 0;
  for (let tr = 0; tr < nTracks; tr++) {
    let tpos = rnd() * 2;
    for (let k = 0; k < per && id < nClips; k++) {
      const dur = 1 + rnd() * 6;
      clips[tr].push({ id, track: tr, start: tpos, dur, label: `Clip ${id + 1}`, hue: (tr * 57 + k * 7) % 360 });
      tpos += dur + (rnd() < 0.3 ? rnd() * 2 : 0); id++;
    }
    duration = Math.max(duration, tpos);
  }
  return { tracks, clips, duration };
}

export type View = { pxPerSec: number; scrollX: number; scrollY: number; playhead: number };

const HEADER_W = 120, RULER_H = 28, TRACK_H = 56, GAP = 4;
const KIND_COLOR: Record<string, string> = { video: '#2d6f8f', audio: '#2f7d4f', text: '#b8692a', effect: '#6d4bb0' };

export class TimelineRenderer {
  ctx: CanvasRenderingContext2D; dpr = window.devicePixelRatio || 1; w = 0; h = 0;
  drawnClips = 0;
  constructor(public canvas: HTMLCanvasElement, public model: TimelineModel, public view: View) {
    this.ctx = canvas.getContext('2d', { alpha: false, desynchronized: false })!;
    this.resize();
  }
  resize() {
    const r = this.canvas.getBoundingClientRect();
    this.w = r.width; this.h = r.height;
    this.canvas.width = Math.round(r.width * this.dpr); this.canvas.height = Math.round(r.height * this.dpr);
  }
  private firstVisible(arr: Clip[], t: number) { // first clip whose end >= t
    let lo = 0, hi = arr.length;
    while (lo < hi) { const m = (lo + hi) >> 1; if (arr[m].start + arr[m].dur < t) lo = m + 1; else hi = m; }
    return lo;
  }
  draw() {
    const { ctx, view, model, dpr, w, h } = this;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = '#17171a'; ctx.fillRect(0, 0, w, h);
    const t0 = view.scrollX / view.pxPerSec, t1 = (view.scrollX + w - HEADER_W) / view.pxPerSec;
    const x = (t: number) => HEADER_W + t * view.pxPerSec - view.scrollX;
    // ruler (adaptive tick spacing)
    const steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300];
    const step = steps.find((s) => s * view.pxPerSec >= 80) ?? 600;
    ctx.fillStyle = '#1e1e22'; ctx.fillRect(HEADER_W, 0, w - HEADER_W, RULER_H);
    ctx.strokeStyle = '#3a3a40'; ctx.fillStyle = '#9a9aa2'; ctx.font = '11px -apple-system, system-ui, sans-serif';
    ctx.beginPath();
    for (let tt = Math.floor(t0 / step) * step; tt <= t1; tt += step) {
      const xx = Math.round(x(tt)) + 0.5; ctx.moveTo(xx, RULER_H - 10); ctx.lineTo(xx, RULER_H);
      const mm = Math.floor(tt / 60), ss = tt % 60;
      ctx.fillText(`${String(mm).padStart(2, '0')}:${ss.toFixed(step < 1 ? 1 : 0).padStart(2, '0')}`, xx + 3, 12);
      for (let k = 1; k < 5; k++) { const sx = Math.round(x(tt + (k * step) / 5)) + 0.5; ctx.moveTo(sx, RULER_H - 4); ctx.lineTo(sx, RULER_H); }
    }
    ctx.stroke();
    // tracks
    let drawn = 0;
    ctx.save(); ctx.beginPath(); ctx.rect(HEADER_W, RULER_H, w - HEADER_W, h - RULER_H); ctx.clip();
    model.tracks.forEach((track, ti) => {
      const y = RULER_H + GAP + ti * (TRACK_H + GAP) - view.scrollY;
      if (y > h || y + TRACK_H < RULER_H) return;
      const arr = model.clips[ti];
      for (let i = this.firstVisible(arr, t0); i < arr.length && arr[i].start <= t1; i++) {
        const c = arr[i];
        const cx = x(c.start), cw = Math.max(1, c.dur * view.pxPerSec - 2);
        ctx.fillStyle = KIND_COLOR[track.kind];
        ctx.beginPath(); ctx.roundRect(cx, y, cw, TRACK_H, 4); ctx.fill();
        if (track.kind === 'video' && cw > 24) {
          // filmstrip placeholder: thumbnails every ~TRACK_H*16/9 px
          const tw = Math.round((TRACK_H - 18) * 16 / 9);
          const visStart = Math.max(cx, HEADER_W - tw), visEnd = Math.min(cx + cw, w);
          for (let tx = cx + Math.floor((visStart - cx) / tw) * tw; tx < visEnd; tx += tw) {
            ctx.fillStyle = `hsl(${(c.hue + tx * 0.05) % 360} 45% 38%)`;
            ctx.fillRect(tx + 1, y + 16, Math.min(tw - 2, cx + cw - tx - 2), TRACK_H - 18);
          }
        } else if (track.kind === 'audio' && cw > 8) {
          ctx.strokeStyle = '#7fd6a0'; ctx.beginPath();
          const mid = y + TRACK_H / 2 + 6;
          const a = Math.max(cx, HEADER_W), b = Math.min(cx + cw, w);
          for (let px = a; px < b; px += 3) { const v = Math.abs(Math.sin(px * 0.13 + c.id) * Math.sin(px * 0.021)) * 16; ctx.moveTo(px, mid - v); ctx.lineTo(px, mid + v); }
          ctx.stroke();
        }
        if (cw > 40) { ctx.fillStyle = '#fff'; ctx.fillText(c.label, Math.max(cx, HEADER_W) + 6, y + 12); }
        drawn++;
      }
    });
    ctx.restore();
    // headers
    ctx.fillStyle = '#1b1b1f'; ctx.fillRect(0, 0, HEADER_W, h);
    ctx.fillStyle = '#c8c8d0';
    model.tracks.forEach((track, ti) => {
      const y = RULER_H + GAP + ti * (TRACK_H + GAP) - view.scrollY;
      ctx.fillText(tr(`track.${track.kind}`) + ` ${ti + 1}`, 10, y + TRACK_H / 2 + 4);
    });
    // playhead
    const px = x(view.playhead);
    if (px >= HEADER_W) { ctx.fillStyle = '#00c1cd'; ctx.fillRect(Math.round(px) - 1, 0, 2, h); }
    this.drawnClips = drawn;
  }
}

export function TimelineCanvas({ onReady }: { onReady: (r: TimelineRenderer) => void }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const r = new TimelineRenderer(ref.current!, makeTimeline(), { pxPerSec: 40, scrollX: 0, scrollY: 0, playhead: 3 });
    r.draw();
    const onResize = () => { r.resize(); r.draw(); };
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      if (e.ctrlKey || e.metaKey) r.view.pxPerSec = Math.min(800, Math.max(2, r.view.pxPerSec * Math.exp(-e.deltaY * 0.01)));
      else r.view.scrollX = Math.max(0, r.view.scrollX + e.deltaX + e.deltaY);
      r.draw();
    };
    window.addEventListener('resize', onResize);
    ref.current!.addEventListener('wheel', onWheel, { passive: false });
    onReady(r);
    return () => window.removeEventListener('resize', onResize);
  }, []);
  return <canvas ref={ref} className="timeline" aria-label={tr('timeline.label')} />;
}
