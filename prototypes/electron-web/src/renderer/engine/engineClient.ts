// UI-thread proxy for the engine worker.
import type { PlayStats } from './player';

export class EngineClient {
  private w = new Worker(new URL('./engineWorker.ts', import.meta.url), { type: 'module' });
  private seq = 0;
  private pending = new Map<number, { res: (v: any) => void; rej: (e: Error) => void }>();
  duration = 0;
  constructor() {
    this.w.onmessage = (e) => {
      const p = this.pending.get(e.data.id); if (!p) return; this.pending.delete(e.data.id);
      if (e.data.ok) p.res(e.data.result); else p.rej(new Error(e.data.error));
    };
  }
  private call<T>(msg: Record<string, unknown>, transfer: Transferable[] = []): Promise<T> {
    const id = ++this.seq;
    return new Promise<T>((res, rej) => { this.pending.set(id, { res, rej }); this.w.postMessage({ ...msg, id }, transfer); });
  }
  async init(canvas: HTMLCanvasElement, clips: string[]) {
    const off = canvas.transferControlToOffscreen();
    const r = await this.call<{ duration: number }>({ cmd: 'init', canvas: off, clips }, [off]);
    this.duration = r.duration;
  }
  play(from: number, rate = 1) { return this.call<void>({ cmd: 'play', from, rate }); }
  stop() { return this.call<PlayStats>({ cmd: 'stop' }); }
  seek(t: number) { return this.call<void>({ cmd: 'seek', t }); }
  async close() { await this.call({ cmd: 'close' }); this.w.terminate(); }
}
