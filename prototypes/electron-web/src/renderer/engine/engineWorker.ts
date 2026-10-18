// Playback engine worker: demux + WebCodecs decode + WebGPU compositing on an OffscreenCanvas,
// clocked by the worker's own requestAnimationFrame. The UI thread (React, timeline) never blocks playback.
import { Compositor } from './compositor';
import { ClipSource } from './decoder';
import { Player } from './player';

(globalThis as any).DEBUG_SEEK = false; // set true to log per-seek timings
let comp: Compositor | null = null;
let player: Player | null = null;

type Msg =
  | { id: number; cmd: 'init'; canvas: OffscreenCanvas; clips: string[] }
  | { id: number; cmd: 'play'; from: number; rate: number }
  | { id: number; cmd: 'stop' }
  | { id: number; cmd: 'seek'; t: number }
  | { id: number; cmd: 'close' };

self.onmessage = async (e: MessageEvent<Msg>) => {
  const m = e.data;
  try {
    let result: unknown = null;
    switch (m.cmd) {
      case 'init': {
        comp = await Compositor.create(m.canvas, 1920, 1080);
        const sources = await Promise.all(m.clips.map((u) => ClipSource.open(u)));
        player = new Player(comp, sources);
        result = { duration: player.duration };
        break;
      }
      case 'play': await player!.play(m.from, m.rate); break;
      case 'stop': result = player!.stop(); break;
      case 'seek': {
        await player!.seek(m.t);
        await comp!.device.queue.onSubmittedWorkDone(); // GPU done compositing the requested frame
        break;
      }
      case 'close': player?.close(); break;
    }
    (self as unknown as Worker).postMessage({ id: m.id, ok: true, result });
  } catch (err) {
    (self as unknown as Worker).postMessage({ id: m.id, ok: false, error: String((err as Error)?.stack ?? err) });
  }
};
