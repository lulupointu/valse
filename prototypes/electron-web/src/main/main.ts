// Montage (Electron prototype) — main process.
// Responsibilities: window, privileged media protocol (range reads), file writes for export,
// process-tree sampling (CPU/RSS of main + GPU + renderer + utility helpers), the whisper.cpp
// sidecar for STT and the ONNX Runtime utility process for segmentation.
import { app, BrowserWindow, ipcMain, protocol, utilityProcess, MessageChannelMain } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { Readable } from 'node:stream';

const args = new Map<string, string>();
for (const a of process.argv.slice(1)) {
  const m = /^--([\w-]+)(?:=(.*))?$/.exec(a);
  if (m) args.set(m[1], m[2] ?? '1');
}
const STACK = 'electron-web';
const bench = args.get('bench') ?? '';
const mediaDir = path.resolve(args.get('media') ?? path.join(__dirname, '../../../bench/media'));
const modelsDir = path.resolve(args.get('models') ?? path.join(__dirname, '../models'));
const outDir = path.resolve(args.get('out') ?? path.join(app.getPath('temp'), 'montage-proto'));
fs.mkdirSync(outDir, { recursive: true });

function emit(metric: string, value: number | string | boolean, unit: string, extra: Record<string, unknown> = {}) {
  process.stdout.write(JSON.stringify({ stack: STACK, metric, value, unit, ...extra }) + '\n');
}

// ---------- process tree sampling ----------
function parseCpuTime(s: string): number { // [[dd-]hh:]mm:ss.ss -> seconds
  let days = 0;
  if (s.includes('-')) { const [d, r] = s.split('-'); days = +d; s = r; }
  const parts = s.split(':').map(Number);
  let sec = 0;
  for (const p of parts) sec = sec * 60 + p;
  return sec + days * 86400;
}
// [bench harness fix] HW video decode/encode runs in launchd-spawned VideoToolbox XPC services, which are not
// descendants of this process. The other prototypes count the ones spawned for them; do the same here
// (helpers that already existed when we launched belong to other apps and are ignored).
const VT_HELPERS = ['VTDecoderXPCService', 'VTEncoderXPCService'];
const preexistingHelpers = new Set<number>();
try {
  for (const l of execFileSync('ps', ['-A', '-o', 'pid=,comm='], { encoding: 'utf8' }).trim().split('\n')) {
    const m = /^\s*(\d+)\s+(.*)$/.exec(l);
    if (m && VT_HELPERS.includes(path.basename(m[2]))) preexistingHelpers.add(+m[1]);
  }
} catch { /* ignore */ }
function sampleTree(): Promise<{ cpuSec: number; rssKb: number; n: number; byPid: Record<number, string> }> {
  return new Promise((resolve) => {
    execFile('ps', ['-A', '-o', 'pid=,ppid=,rss=,time=,comm='], { maxBuffer: 8 << 20 }, (_e, out) => {
      const rows = out.trim().split('\n').map((l) => {
        const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(l);
        return m ? { pid: +m[1], ppid: +m[2], rss: +m[3], time: m[4], comm: m[5] } : null;
      }).filter(Boolean) as { pid: number; ppid: number; rss: number; time: string; comm: string }[];
      const tree = new Set([process.pid]);
      let grew = true;
      while (grew) { grew = false; for (const r of rows) if (!tree.has(r.pid) && tree.has(r.ppid)) { tree.add(r.pid); grew = true; } }
      for (const r of rows) if (VT_HELPERS.includes(path.basename(r.comm)) && !preexistingHelpers.has(r.pid)) tree.add(r.pid);
      let cpuSec = 0, rssKb = 0; const byPid: Record<number, string> = {};
      for (const r of rows) if (tree.has(r.pid)) { cpuSec += parseCpuTime(r.time); rssKb += r.rss; byPid[r.pid] = path.basename(r.comm); }
      resolve({ cpuSec, rssKb, n: tree.size, byPid });
    });
  });
}
class Sampler {
  private timer?: NodeJS.Timeout; private t0 = 0; private cpu0 = 0; private rss: number[] = []; private procs = 0;
  async start() { const s = await sampleTree(); this.t0 = performance.now(); this.cpu0 = s.cpuSec; this.rss = [];
    this.timer = setInterval(async () => { const x = await sampleTree(); this.rss.push(x.rssKb); this.procs = Math.max(this.procs, x.n); }, 500); }
  async stop() { clearInterval(this.timer); const s = await sampleTree(); const wall = (performance.now() - this.t0) / 1000;
    this.rss.push(s.rssKb);
    const avgRss = this.rss.reduce((a, b) => a + b, 0) / this.rss.length / 1024;
    return { cpuPct: ((s.cpuSec - this.cpu0) / wall) * 100, rssMb: avgRss, rssPeakMb: Math.max(...this.rss) / 1024, procs: Math.max(this.procs, s.n), byPid: s.byPid }; }
}
const sampler = new Sampler();

// ---------- media protocol (HTTP-like range reads for the demuxer) ----------
protocol.registerSchemesAsPrivileged([{ scheme: 'media', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, bypassCSP: true, corsEnabled: true } }]);

function registerMediaProtocol() {
  protocol.handle('media', async (req) => {
    const url = new URL(req.url);
    const file = path.join(url.host === 'models' ? modelsDir : url.host === 'bench' ? path.dirname(mediaDir) : mediaDir, path.basename(decodeURIComponent(url.pathname)));
    const size = (await fs.promises.stat(file)).size;
    const range = req.headers.get('range');
    let start = 0, end = size - 1;
    if (range) { const m = /bytes=(\d*)-(\d*)/.exec(range)!; if (m[1]) start = +m[1]; if (m[2]) end = Math.min(+m[2], size - 1); }
    const len = end - start + 1;
    // Small bounded ranges: one read. Open-ended / large ranges: stream (the demuxer cancels when it has enough).
    let body: BodyInit;
    if (len <= 8 << 20) {
      const fh = await fs.promises.open(file, 'r');
      const buf = Buffer.allocUnsafe(len);
      await fh.read(buf, 0, len, start); await fh.close();
      body = buf;
    } else {
      body = Readable.toWeb(fs.createReadStream(file, { start, end, highWaterMark: 1 << 20 })) as unknown as BodyInit;
    }
    return new Response(body, { status: range ? 206 : 200, headers: {
      'content-length': String(len), 'accept-ranges': 'bytes', 'content-type': file.endsWith('.txt') ? 'text/plain; charset=utf-8' : 'application/octet-stream',
      ...(range ? { 'content-range': `bytes ${start}-${end}/${size}` } : {}) } });
  });
}

// ---------- export file sink ----------
const openFiles = new Map<number, fs.promises.FileHandle>(); let nextFd = 1;
ipcMain.handle('file:open', async (_e, name: string) => { const p = path.join(outDir, name); const fh = await fs.promises.open(p, 'w'); const id = nextFd++; openFiles.set(id, fh); return { id, path: p }; });
ipcMain.handle('file:write', async (_e, id: number, data: Uint8Array, pos: number) => { await openFiles.get(id)!.write(data, 0, data.byteLength, pos); });
ipcMain.handle('file:close', async (_e, id: number) => { await openFiles.get(id)!.close(); openFiles.delete(id); });

// ---------- misc IPC ----------
ipcMain.handle('screenshot', async (_e, name: string) => { const img = await win.webContents.capturePage(); const p = path.join(outDir, name); await fs.promises.writeFile(p, img.toPNG()); return p; });
ipcMain.handle('config', () => ({ bench, mediaDir, modelsDir, outDir, args: Object.fromEntries(args), t0: Number(args.get('t0') ?? 0) }));
ipcMain.handle('emit', (_e, metric: string, value: number | string | boolean, unit: string, extra?: Record<string, unknown>) => emit(metric, value, unit, extra));
ipcMain.handle('log', (_e, ...m: unknown[]) => { process.stderr.write('[renderer] ' + m.map(String).join(' ') + '\n'); });
ipcMain.handle('sampler:start', () => sampler.start());
ipcMain.handle('sampler:stop', () => sampler.stop());
ipcMain.handle('done', (_e, code = 0) => { setTimeout(() => app.exit(code), 50); });
ipcMain.handle('probe', (_e, file: string) => new Promise((res) => {
  execFile('ffprobe', ['-v', 'error', '-show_entries', 'stream=codec_name,width,height,nb_frames,avg_frame_rate:format=duration', '-of', 'json', file], (_err, out) => res(out));
}));

// ---------- STT: whisper.cpp sidecar (Metal) ----------
ipcMain.handle('stt:run', async (_e, wavName: string) => {
  const model = path.join(modelsDir, 'ggml-large-v3-turbo-q5_0.bin');
  const wav = path.join(mediaDir, wavName);
  const base = path.join(outDir, 'stt');
  const bin = args.get('whisper') ?? 'whisper-cli';
  const t0 = performance.now();
  await new Promise<void>((resolve, reject) => {
    const p = spawn(bin, ['-m', model, '-f', wav, '-l', 'fr', '-ojf', '-of', base, '-np', '-t', '4', '--dtw', 'large.v3.turbo'], { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = ''; p.stderr.on('data', (d) => { err += d; });
    p.on('exit', (c) => (c === 0 ? resolve() : reject(new Error('whisper-cli failed: ' + err.slice(-2000)))));
  });
  const wallMs = performance.now() - t0;
  const wavBuf = await fs.promises.readFile(wav);
  const audioSec = (wavBuf.length - 44) / (wavBuf.readUInt32LE(28)); // byteRate from WAV header
  return { wallMs, audioSec, json: JSON.parse(await fs.promises.readFile(base + '.json', 'utf8')) };
});

// ---------- Segmentation: ONNX Runtime in an Electron utility process ----------
let segProc: Electron.UtilityProcess | null = null;
ipcMain.on('seg:connect', (e, opts: { ep: string; width: number; height: number; downsample: number }) => {
  segProc = utilityProcess.fork(path.join(__dirname, 'segUtility.js'), [], { serviceName: 'montage-seg', stdio: 'inherit' });
  segProc.on('exit', (code) => { if (code !== 0) { process.stderr.write(`[main] seg utility exited with ${code}\n`); if (bench) app.exit(5); } });
  const { port1, port2 } = new MessageChannelMain();
  segProc.postMessage({ type: 'init', model: path.join(modelsDir, 'rvm_mobilenetv3_fp32.onnx'), ...opts }, [port1]);
  e.sender.postMessage('seg:port', null, [port2]);
});

// ---------- window ----------
let win: BrowserWindow;
app.commandLine.appendSwitch('enable-unsafe-webgpu'); // no-op on macOS where WebGPU is on by default; harmless
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-background-timer-throttling');
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

app.whenReady().then(() => {
  registerMediaProtocol();
  win = new BrowserWindow({
    width: 1600, height: 1000, show: false, backgroundColor: '#121214', title: 'Montage',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: false, backgroundThrottling: false },
  });
  win.once('ready-to-show', () => win.show());
  win.loadFile(path.join(__dirname, 'renderer/index.html'));
  if (bench) {
    const watchdog = Number(args.get('timeout') ?? 300) * 1000;
    setTimeout(() => { process.stderr.write(`[main] watchdog timeout for ${bench}\n`); app.exit(3); }, watchdog).unref();
  }
  win.webContents.on('render-process-gone', (_e, d) => { process.stderr.write(`[main] renderer gone ${d.reason}\n`); if (bench) app.exit(4); });
  win.webContents.on('console-message', (e) => { if (args.get('verbose')) process.stderr.write(`[console] ${e.message}\n`); });
});
app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => { segProc?.kill(); });
