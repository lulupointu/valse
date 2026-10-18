// Typed access to the preload bridge.
export type HostConfig = { bench: string; mediaDir: string; modelsDir: string; outDir: string; args: Record<string, string>; t0: number };
export interface Host {
  config(): Promise<HostConfig>;
  emit(metric: string, value: unknown, unit: string, extra?: Record<string, unknown>): Promise<void>;
  log(...m: unknown[]): Promise<void>;
  samplerStart(): Promise<void>;
  samplerStop(): Promise<{ cpuPct: number; rssMb: number; rssPeakMb: number; procs: number; byPid: Record<number, string> }>;
  done(code?: number): Promise<void>;
  screenshot(name: string): Promise<string>;
  probe(file: string): Promise<string>;
  fileOpen(name: string): Promise<{ id: number; path: string }>;
  fileWrite(id: number, data: Uint8Array, pos: number): Promise<void>;
  fileClose(id: number): Promise<void>;
  stt(wav: string): Promise<{ wallMs: number; audioSec: number; json: any }>;
  segConnect(opts: object): Promise<void>;
}
export const host = (window as unknown as { host: Host }).host;
export const mediaUrl = (name: string) => `media://local/${encodeURIComponent(name)}`;
