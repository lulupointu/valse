// GOP-aware WebCodecs decoder for one clip (hardware VideoToolbox decode via Chromium).
// Demuxing: mediabunny (range reads over the privileged media:// protocol).
// Holds a small bounded queue of decoded VideoFrames (IOSurface-backed => zero-copy GPU import).
import { Input, ALL_FORMATS, UrlSource, EncodedPacketSink, type EncodedPacket, type InputVideoTrack } from 'mediabunny';

export class ClipSource {
  input!: Input; track!: InputVideoTrack; packets!: EncodedPacketSink; config!: VideoDecoderConfig;
  duration = 0; width = 0; height = 0;
  static async open(url: string) {
    const s = new ClipSource();
    s.input = new Input({ source: new UrlSource(url), formats: ALL_FORMATS });
    s.track = (await s.input.getPrimaryVideoTrack())!;
    s.packets = new EncodedPacketSink(s.track);
    s.config = { ...(await s.track.getDecoderConfig())!, hardwareAcceleration: 'prefer-hardware', optimizeForLatency: true };
    s.duration = await s.track.computeDuration();
    s.width = s.track.displayWidth; s.height = s.track.displayHeight;
    return s;
  }
}

const EPS = 1e-3;

export class LayerDecoder {
  private decoder!: VideoDecoder;
  private queue: VideoFrame[] = [];
  private gen = 0;               // incremented on every reset; stale outputs are dropped
  private minTs = 0;             // drop decoded frames earlier than this (seconds)
  private iter: AsyncGenerator<EncodedPacket> | null = null;
  private feeding = false;
  private ended = false;
  private waiters: (() => void)[] = [];
  private currentKeyTs = -1;
  lastOutTs = -1;
  constructor(public src: ClipSource, public maxQueue = 4) { this.makeDecoder(); }

  private makeDecoder() {
    this.decoder = new VideoDecoder({
      output: (f) => {
        const ts = f.timestamp / 1e6;
        if (ts < this.minTs - EPS) { f.close(); this.pump(); return; }
        this.queue.push(f); this.lastOutTs = ts; this.wake();
      },
      error: (e) => console.error('decoder error', e),
    });
    this.decoder.configure(this.src.config);
    this.decoder.addEventListener('dequeue', () => this.pump());
  }

  private wake() { const w = this.waiters; this.waiters = []; for (const f of w) f(); }

  /** Start (or restart) decoding so that frames with ts >= t become available. */
  async startAt(t: number) {
    const key = await this.src.packets.getKeyPacket(t) ?? await this.src.packets.getFirstKeyPacket();
    // Fast path: target is ahead of us within the GOP we are already decoding -> keep going.
    const canContinue = key && key.timestamp === this.currentKeyTs && t >= this.lastOutTs - EPS && !this.ended;
    this.minTs = t;
    for (const f of this.queue.splice(0)) { if (f.timestamp / 1e6 >= t - EPS && canContinue) this.queue.push(f); else f.close(); }
    if (canContinue) { this.pump(); return; }
    this.gen++;
    this.iter?.return(undefined);
    // Reuse the decoder (reset drops pending outputs; reconfigure with the same config keeps the HW session cheap).
    if (this.decoder.state === 'closed') this.makeDecoder();
    else { this.decoder.reset(); this.decoder.configure(this.src.config); }
    this.ended = false; this.lastOutTs = -1;
    this.currentKeyTs = key ? key.timestamp : -1;
    this.iter = this.src.packets.packets(key ?? undefined);
    this.pump();
  }

  private async pump() {
    if (this.feeding || !this.iter) return;
    this.feeding = true;
    const gen = this.gen;
    try {
      while (gen === this.gen && !this.ended && this.queue.length + this.decoder.decodeQueueSize < this.maxQueue) {
        const r = await this.iter.next();
        if (gen !== this.gen) break;
        if (r.done) { this.ended = true; await this.decoder.flush().catch(() => {}); this.wake(); break; }
        const p = r.value;
        if (p.type === 'key') this.currentKeyTs = p.timestamp;
        this.decoder.decode(p.toEncodedVideoChunk());
        // Chromium's VT decoder may hold a few frames before emitting; prod a flush near a seek target.
      }
    } finally { this.feeding = false; }
  }

  /** Latest frame with ts <= t (non-blocking). Older frames are released. Returns null if none ready. */
  frameAt(t: number): VideoFrame | null {
    let best = -1;
    for (let i = 0; i < this.queue.length; i++) if (this.queue[i].timestamp / 1e6 <= t + EPS) best = i;
    if (best < 0) return null;
    if (best > 0) { for (const f of this.queue.splice(0, best)) f.close(); this.pump(); }
    return this.queue[0];
  }

  /** Wait until a frame covering t is decoded (ts <= t < ts+frameDur), used by scrub and export. */
  async waitFrame(t: number, frameDur = 1 / 30): Promise<VideoFrame | null> {
    for (;;) {
      const last = this.queue[this.queue.length - 1];
      if (last && last.timestamp / 1e6 + frameDur > t + EPS) { const f = this.frameAt(t); if (f) return f; }
      if (this.ended) return this.frameAt(t);
      // A hardware decoder may keep a couple of frames internally; when we are starved and nothing is queued
      // for decode, flush to force them out.
      if (!this.feeding && this.decoder.decodeQueueSize === 0 && this.queue.length < this.maxQueue) this.pump();
      await new Promise<void>((r) => { this.waiters.push(r); setTimeout(r, 4); });
    }
  }

  close() { this.gen++; this.iter?.return(undefined); for (const f of this.queue.splice(0)) f.close(); if (this.decoder.state !== 'closed') this.decoder.close(); }
}
