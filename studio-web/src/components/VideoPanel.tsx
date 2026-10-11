// Onboard video synced to the data. The file is opened locally and never uploaded.

import { useEffect, useRef, useState } from 'react';
import { cursor, useCursor } from '../state/cursor';
import { nearestS, positionAtTime } from '../lib/workspace';
import type { LapData } from '../lib/types';
import type { Workspace } from '../lib/workspace';

interface Props {
  ws: Workspace;
  lap: LapData;
  /** Unix seconds when "Mark video start" was tapped, from the CSV. */
  videoStartUtc: number | null;
}

export function VideoPanel({ ws, lap, videoStartUtc }: Props) {
  const [url, setUrl] = useState<string | null>(null);
  const [name, setName] = useState('');
  // Seconds into the video at which this lap starts.
  const [offset, setOffset] = useState(0);
  const video = useRef<HTMLVideoElement>(null);
  const c = useCursor();

  useEffect(() => () => { if (url) URL.revokeObjectURL(url); }, [url]);
  useEffect(() => {
    setOffset(videoStartUtc != null ? Math.max(0, lap.startTime - videoStartUtc) : 0);
  }, [lap.key, lap.startTime, videoStartUtc]);

  // Video playing → move the shared cursor.
  useEffect(() => {
    const v = video.current;
    if (!v || !url) return;
    let raf = 0;
    const tick = () => {
      const lt = v.currentTime - offset;
      if (lt >= 0 && lt <= lap.time) {
        const pos = positionAtTime(lap, lt);
        const s = pos ? nearestS(ws, pos[0], pos[1], 40) : null;
        if (s != null) cursor.set({ s, time: lt, src: 'video' });
      }
      if (!v.paused) raf = requestAnimationFrame(tick);
    };
    const onPlay = () => { raf = requestAnimationFrame(tick); };
    const onSeek = () => tick();
    v.addEventListener('play', onPlay); v.addEventListener('seeked', onSeek);
    return () => { cancelAnimationFrame(raf); v.removeEventListener('play', onPlay); v.removeEventListener('seeked', onSeek); };
  }, [url, offset, lap, ws]);

  // Cursor moved elsewhere while paused → seek the video.
  useEffect(() => {
    const v = video.current;
    if (!v || !url || !v.paused || c.src === 'video' || c.s == null) return;
    let lt = c.time;
    const al = ws.aligned.get(lap.key);
    if (lt == null && al) {
      const rs = ws.ref.s;
      let lo = 0, hi = rs.length - 1;
      while (lo < hi) { const m = (lo + hi) >> 1; if (rs[m] < c.s) lo = m + 1; else hi = m; }
      lt = al.t[lo];
    }
    if (lt != null && Number.isFinite(lt)) v.currentTime = Math.max(0, offset + lt);
  }, [c, url, offset, ws, lap.key]);

  const open = (f: File | undefined) => {
    if (!f) return;
    if (url) URL.revokeObjectURL(url);
    setUrl(URL.createObjectURL(f)); setName(f.name);
  };
  const nudge = (d: number) => setOffset((o) => Math.max(0, Math.round((o + d) * 10) / 10));

  return (
    <section className="card video">
      <header className="card-head"><h2>Onboard video</h2>{name && <span className="hint">{name}</span>}</header>
      {!url ? (
        <div className="video-empty">
          <p>Open a video from this session to watch it in step with your data. It stays on your computer.</p>
          <label className="btn" htmlFor="video-file">Open video…</label>
          <input id="video-file" type="file" accept="video/*" className="sr-only" onChange={(e) => open(e.target.files?.[0])} />
          {videoStartUtc == null && <p className="hint">This session has no video mark, so line it up by hand with the buttons under the video.</p>}
        </div>
      ) : (
        <>
          <video ref={video} src={url} controls playsInline className="video-el" />
          <div className="video-sync">
            <span>Lap {lap.label} starts at <b>{offset.toFixed(1)} s</b></span>
            <div className="video-nudge">
              {[-1, -0.1, 0.1, 1].map((d) => <button key={d} type="button" className="btn btn--small" onClick={() => nudge(d)}>{d > 0 ? '+' : '−'}{Math.abs(d)} s</button>)}
              <button type="button" className="btn btn--small" onClick={() => { if (video.current) setOffset(Math.round(video.current.currentTime * 10) / 10); }}>Lap starts here</button>
            </div>
          </div>
          <label className="link" htmlFor="video-file">Open a different video</label>
          <input id="video-file" type="file" accept="video/*" className="sr-only" onChange={(e) => open(e.target.files?.[0])} />
        </>
      )}
    </section>
  );
}
