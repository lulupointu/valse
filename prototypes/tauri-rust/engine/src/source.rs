//! A clip source = a decode thread per clip that reads ahead into a small bounded queue
//! (bounded => bounded memory: at most QUEUE IOSurfaces per clip in flight), plus a second,
//! random-access decoder used for scrubbing so seeks never tear down the playback decoder.
use crate::decode::{VideoFrame, VideoReader};
use crossbeam_channel::{bounded, select, unbounded, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

const QUEUE: usize = 4;

enum Cmd {
    Play { t: f64, gen: u64 },
    Scrub { t: f64, gen: u64 },
    Stop,
}

pub struct ClipSource {
    cmd: Sender<Cmd>,
    rx: Receiver<(u64, VideoFrame)>,
    gen: u64,
    pending: Option<VideoFrame>,
    pub current: Option<VideoFrame>,
    pub fps: f64,
    pub duration: f64,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl ClipSource {
    pub fn open(path: &str) -> anyhow::Result<Self> {
        let probe = VideoReader::open(path)?;
        let (fps, duration) = (probe.fps, probe.duration);
        drop(probe);
        let (cmd_tx, cmd_rx) = unbounded::<Cmd>();
        let (tx, rx) = bounded::<(u64, VideoFrame)>(QUEUE);
        let p = path.to_string();
        let thread = std::thread::Builder::new()
            .name(format!("decode:{}", path.rsplit('/').next().unwrap_or(path)))
            .spawn(move || decode_thread(p, cmd_rx, tx))?;
        Ok(ClipSource { cmd: cmd_tx, rx, gen: 0, pending: None, current: None, fps, duration, thread: Some(thread) })
    }

    /// Start sequential playback decode from `t`.
    pub fn play_from(&mut self, t: f64) {
        self.gen += 1;
        self.pending = None;
        let _ = self.cmd.send(Cmd::Play { t, gen: self.gen });
    }

    /// Request a single frame at `t` (random-access decoder). Non-blocking; use `wait_scrub`.
    pub fn request_scrub(&mut self, t: f64) {
        self.gen += 1;
        self.pending = None;
        let _ = self.cmd.send(Cmd::Scrub { t, gen: self.gen });
    }

    pub fn wait_scrub(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            match self.rx.recv_deadline(deadline) {
                Ok((g, f)) if g == self.gen => {
                    self.current = Some(f);
                    return true;
                }
                Ok(_) => continue,
                Err(_) => return false,
            }
        }
    }

    /// Advance to the newest frame with pts <= t (+half frame). Waits until `deadline` for the
    /// decoder if no suitable frame is queued yet. Returns true if `current` is on time.
    pub fn advance_to(&mut self, t: f64, deadline: Instant) -> bool {
        let half = 0.5 / self.fps;
        loop {
            if self.pending.is_none() {
                let on_time = self.current.as_ref().map(|c| (c.pts - t).abs() < half * 1.01 || c.pts > t).unwrap_or(false);
                let r = if on_time {
                    self.rx.try_recv().map_err(|_| RecvTimeoutError::Timeout)
                } else {
                    self.rx.recv_deadline(deadline)
                };
                match r {
                    Ok((g, f)) if g == self.gen => self.pending = Some(f),
                    Ok(_) => continue,
                    Err(_) => break,
                }
            }
            let p = self.pending.as_ref().unwrap();
            if p.pts <= t + half {
                self.current = self.pending.take();
            } else {
                break;
            }
        }
        self.current.as_ref().map(|c| (c.pts - t).abs() < half * 1.01).unwrap_or(false)
    }
}

impl Drop for ClipSource {
    fn drop(&mut self) {
        let _ = self.cmd.send(Cmd::Stop);
        // unblock the sender
        while self.rx.try_recv().is_ok() {}
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn decode_thread(path: String, cmd_rx: Receiver<Cmd>, tx: Sender<(u64, VideoFrame)>) {
    let mut play = match VideoReader::open(&path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("decode open failed: {e}");
            return;
        }
    };
    let mut scrub = VideoReader::open(&path).ok();
    let mut playing: Option<u64> = None;
    let mut next_cmd: Option<Cmd> = None;
    loop {
        let cmd = if let Some(c) = next_cmd.take() {
            Some(c)
        } else if playing.is_none() {
            match cmd_rx.recv() {
                Ok(c) => Some(c),
                Err(_) => return,
            }
        } else {
            cmd_rx.try_recv().ok()
        };
        match cmd {
            Some(Cmd::Stop) => return,
            Some(Cmd::Play { t, gen }) => {
                if let Err(e) = play.start(t) {
                    eprintln!("play start failed: {e}");
                    playing = None;
                } else {
                    playing = Some(gen);
                }
            }
            Some(Cmd::Scrub { t, gen }) => {
                playing = None;
                if let Some(s) = scrub.as_mut() {
                    match s.seek_random_access(t) {
                        Ok(Some(f)) => {
                            let _ = tx.send((gen, f));
                        }
                        Ok(None) => {}
                        Err(e) => eprintln!("scrub failed: {e}"),
                    }
                }
            }
            None => {}
        }
        if let Some(gen) = playing {
            match play.next() {
                Some(f) => {
                    select! {
                        send(tx, (gen, f)) -> res => { if res.is_err() { return; } }
                        recv(cmd_rx) -> c => { match c { Ok(c) => next_cmd = Some(c), Err(_) => return } }
                    }
                }
                None => playing = None,
            }
        }
    }
}
