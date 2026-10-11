// One corner drawn from your reference lap, with where you braked, turned in,
// reached the apex and picked up the throttle. A teaching view for new drivers.

import { useEffect, useMemo, useState } from 'react';
import { cursor } from '../state/cursor';
import { fmtSpeed, speedUnit } from '../lib/format';
import type { Workspace } from '../lib/workspace';

interface Props { ws: Workspace; focusKey: string; focusLabel: string }

const W = 320, H = 220, PAD = 22;

function idxAt(s: Float64Array, v: number): number {
  let lo = 0, hi = s.length - 1;
  while (lo < hi) { const m = (lo + hi) >> 1; if (s[m] < v) lo = m + 1; else hi = m; }
  return lo;
}

export function CornerExplainer({ ws, focusKey, focusLabel }: Props) {
  const [num, setNum] = useState<number>(ws.corners[0]?.number ?? 0);
  const corner = ws.corners.find((c) => c.number === num) ?? ws.corners[0];
  const stats = ws.stats.get(focusKey)?.find((c) => c.corner === corner?.number);
  const reduced = typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  const [t, setT] = useState(0);

  useEffect(() => {
    if (reduced) return;
    let raf = 0; const t0 = performance.now();
    const tick = (now: number) => { setT(((now - t0) / 4000) % 1); raf = requestAnimationFrame(tick); };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [reduced]);

  const geom = useMemo(() => {
    if (!corner) return null;
    const { s, x, y } = ws.ref;
    const a = idxAt(s, Math.max(corner.zoneStart, (stats && Number.isFinite(stats.brakeS) ? stats.brakeS : corner.sStart) - 40));
    const b = idxAt(s, Math.min(corner.zoneEnd, (stats && Number.isFinite(stats.throttleS) ? stats.throttleS : corner.sEnd) + 60));
    if (b - a < 3) return null;
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    for (let i = a; i <= b; i++) { x0 = Math.min(x0, x[i]); x1 = Math.max(x1, x[i]); y0 = Math.min(y0, y[i]); y1 = Math.max(y1, y[i]); }
    const k = Math.min((W - 2 * PAD) / Math.max(1, x1 - x0), (H - 2 * PAD) / Math.max(1, y1 - y0));
    const ox = (W - (x1 - x0) * k) / 2, oy = (H - (y1 - y0) * k) / 2;
    const P = (i: number): [number, number] => [ox + (x[i] - x0) * k, H - (oy + (y[i] - y0) * k)];
    const pts: [number, number][] = [];
    for (let i = a; i <= b; i++) pts.push(P(i));
    const at = (sv: number) => (Number.isFinite(sv) ? P(Math.min(b, Math.max(a, idxAt(s, sv)))) : null);
    return { a, b, pts, at };
  }, [ws, corner, stats]);

  if (!corner || !geom) return null;
  const marks = [
    { key: 'brake', label: 'Brake', p: stats ? geom.at(stats.brakeS) : null, cls: 'mk-brake' },
    { key: 'turn', label: 'Turn in', p: geom.at(corner.sStart), cls: 'mk-turn' },
    { key: 'apex', label: 'Slowest', p: geom.at(stats ? stats.minS : corner.sApex), cls: 'mk-apex' },
    { key: 'throttle', label: 'Throttle', p: stats ? geom.at(stats.throttleS) : null, cls: 'mk-throttle' },
  ];
  const dot = geom.pts[Math.floor((reduced ? 0.5 : t) * (geom.pts.length - 1))];
  const path = geom.pts.map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ');

  return (
    <section className="card explainer">
      <header className="card-head">
        <h2>Corner by corner</h2>
        <label className="hint" htmlFor="explainer-corner">Lap {focusLabel} · </label>
        <select id="explainer-corner" value={corner.number} onChange={(e) => { const n = Number(e.target.value); setNum(n); const c = ws.corners.find((x) => x.number === n); if (c) cursor.set({ s: c.sApex, time: null, src: 'explainer' }); }}>
          {ws.corners.map((c) => <option key={c.number} value={c.number}>Turn {c.number} ({c.direction === 'L' ? 'left' : 'right'}, {Math.round(c.angle)}°)</option>)}
        </select>
      </header>
      <svg viewBox={`0 0 ${W} ${H}`} className="explainer-svg" role="img" aria-label={`Turn ${corner.number} with braking, turn-in, slowest point and throttle markers`}>
        <path d={path} className="ex-track" />
        <path d={path} className="ex-line" />
        {marks.map((m) => m.p && (
          <g key={m.key} className={m.cls}>
            <circle cx={m.p[0]} cy={m.p[1]} r="6" />
            <text x={m.p[0] + 9} y={m.p[1] - 8}>{m.label}</text>
          </g>
        ))}
        {dot && <circle cx={dot[0]} cy={dot[1]} r="4.5" className="ex-dot" />}
      </svg>
      {stats && stats.valid ? (
        <dl className="ex-figs">
          <div><dt>Entry</dt><dd>{fmtSpeed(stats.entrySpeed)} {speedUnit()}</dd></div>
          <div><dt>Slowest</dt><dd>{fmtSpeed(stats.minSpeed)} {speedUnit()}</dd></div>
          <div><dt>Exit</dt><dd>{fmtSpeed(stats.exitSpeed)} {speedUnit()}</dd></div>
          <div><dt>Brake → slowest</dt><dd>{Number.isFinite(stats.brakeS) ? `${Math.round(stats.minS - stats.brakeS)} m` : '—'}</dd></div>
        </dl>
      ) : <p className="hint">No clean data for this lap in turn {corner.number}.</p>}
      <p className="footnote">Brake in a straight line, turn in once the braking is mostly done, and squeeze the throttle only once you can see the exit. The shape is drawn from your reference lap.</p>
    </section>
  );
}
