import { useEffect, useRef, useState } from 'react';
import { TimelineCanvas, type TimelineRenderer } from './timeline/TimelineCanvas';
import { host } from './host';
import { t } from './i18n';
import { runBench } from './bench/runner';

export function App() {
  const playerRef = useRef<HTMLCanvasElement>(null);
  const [timeline, setTimeline] = useState<TimelineRenderer | null>(null);
  const [status, setStatus] = useState('');
  useEffect(() => {
    if (!timeline) return;
    (async () => {
      const cfg = await host.config();
      if (!cfg.bench) return;
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); // shell painted
      runBench({ cfg, playerCanvas: playerRef.current!, timeline, setStatus: (s) => setStatus(t('bench.running', { name: s })) });
    })();
  }, [timeline]);
  const nClips = timeline ? timeline.model.clips.reduce((n, a) => n + a.length, 0) : 0;
  return (
    <div className="app">
      <div className="titlebar"><strong>{t('app.title')}</strong><span>{t('clips.count', { n: nClips })}</span><span className="status">{status}</span></div>
      <div className="top">
        <div className="panel"><h2>{t('media.title')}</h2><div className="thumbs">{Array.from({ length: 9 }, (_, i) => <div key={i} />)}</div></div>
        <div className="player" aria-label={t('player.label')}><canvas ref={playerRef} width={1920} height={1080} /></div>
        <div className="panel"><h2>{t('inspector.title')}</h2><p>{t('inspector.empty')}</p></div>
      </div>
      <div className="toolbar">
        <button>{t('toolbar.undo')}</button><button>{t('toolbar.redo')}</button><button>{t('toolbar.split')}</button>
        <span style={{ flex: 1 }} /><button>{t('toolbar.export')}</button>
      </div>
      <TimelineCanvas onReady={setTimeline} />
    </div>
  );
}
