import { invoke } from "@tauri-apps/api/core";
import { apply, setLang, t } from "./i18n";
import { makeClips, Timeline } from "./timeline";

interface BenchConfig { mode: string; duration: number; lang: string }

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

async function main() {
  const cfg = await invoke<BenchConfig>("bench_config");
  setLang(cfg.lang || navigator.language || "en");
  ($("lang-select") as HTMLSelectElement).value = cfg.lang.startsWith("fr") || navigator.language.startsWith("fr") ? "fr" : "en";
  $("lang-select").addEventListener("change", (e) => { setLang((e.target as HTMLSelectElement).value); tl.draw(); });

  const grid = $("asset-grid");
  for (let i = 0; i < 12; i++) { const d = document.createElement("div"); d.textContent = `clip_${i + 1}.mp4`; grid.appendChild(d); }

  // Native player placement: send the hole's rect (CSS px) to Rust, which moves the NSView.
  const hole = $("player-hole");
  const sendRect = () => {
    const r = hole.getBoundingClientRect();
    invoke("set_player_rect", { x: r.left, y: r.top, w: r.width, h: r.height });
  };
  new ResizeObserver(sendRect).observe(hole);
  window.addEventListener("resize", sendRect);
  sendRect();

  const TRACKS = 6, N = 500;
  const tl = new Timeline($("timeline") as HTMLCanvasElement, makeClips(N, TRACKS), TRACKS);
  $("clip-count").textContent = t("timeline.clips", { n: N, t: TRACKS });

  let playing = false;
  $("play-btn").addEventListener("click", () => {
    playing = !playing;
    invoke(playing ? "player_play" : "player_pause", playing ? { rate: 1 } : {});
    $("play-btn").textContent = t(playing ? "action.pause" : "action.play");
  });
  // click on ruler/timeline = seek (scrub)
  $("timeline").addEventListener("mousedown", async (e) => {
    const tt = Math.max(0, tl.scrollX + (e.offsetX - 90) / tl.pxPerSec) % 59;
    tl.playhead = tt; tl.draw();
    const ms = await invoke<number>("player_seek", { t: tt });
    $("player-status").textContent = t("player.seek", { ms: ms.toFixed(1) });
  });
  setInterval(async () => {
    if (!playing) return;
    const mt = await invoke<number>("player_time");
    const f = Math.floor(mt * 30) % 30, s = Math.floor(mt);
    $("timecode").textContent = `00:00:${String(s).padStart(2, "0")}:${String(f).padStart(2, "0")}`;
    tl.playhead = mt; tl.draw();
  }, 100);

  apply();
  await invoke("ui_ready");

  if (cfg.mode === "timeline") runTimelineBench(tl);
}

// P4: programmatic scroll + zoom animation for 5 s, counting rendered frames.
function runTimelineBench(tl: Timeline) {
  const DURATION = 5000;
  let frames = 0, start = 0, worst = 0, last = 0;
  const step = (now: number) => {
    if (!start) { start = now; last = now; }
    const el = now - start;
    worst = Math.max(worst, now - last); last = now;
    const p = el / DURATION;
    tl.pxPerSec = 10 + 190 * (0.5 - 0.5 * Math.cos(p * Math.PI * 4)); // zoom in/out twice
    tl.scrollX = p * (tl.totalDur - (tl.width - 90) / tl.pxPerSec) * 0.9;
    tl.playhead = tl.scrollX + 5;
    tl.draw();
    frames++;
    if (el < DURATION) requestAnimationFrame(step);
    else {
      const fps = (frames - 1) / (el / 1000);
      document.getElementById("tl-fps")!.textContent = `${fps.toFixed(1)} fps`;
      console.log("timeline worst frame ms", worst);
      invoke("bench_result", { metric: "timeline_fps", value: fps, unit: "fps" });
    }
  };
  requestAnimationFrame(step);
}

main();
