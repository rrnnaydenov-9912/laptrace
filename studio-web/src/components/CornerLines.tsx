// Two laps' lines drawn through one corner on top of the track, with each lap's
// brake point, slowest point and throttle pick-up. The full view also replays both
// laps through the corner in real time, so you can see who pulls ahead and where.

import { useEffect, useMemo, useState } from 'react';
import { cornerLines } from '../lib/cornerLines';
import type { Corner } from '../lib/corners';
import type { Workspace } from '../lib/workspace';

interface Props {
  ws: Workspace;
  corner: Corner;
  /** Lap being coached first, comparison lap second. */
  keys: [string, string | null];
  variant: 'full' | 'thumb';
  label: string;
}

const SIZE = {
  full: { W: 360, H: 240, PAD: 26, band: 18, line: 2.6, minGapPx: 9 },
  thumb: { W: 132, H: 92, PAD: 9, band: 9, line: 1.8, minGapPx: 5 },
};
const MAX_EXAGGERATION = 4;

const ROLE = ['cl-a', 'cl-b'];

export function CornerLines({ ws, corner, keys, variant, label }: Props) {
  const z = SIZE[variant];
  const geo = useMemo(
    () => cornerLines(ws, corner, keys.filter((k): k is string => !!k)),
    [ws, corner, keys[0], keys[1]], // eslint-disable-line react-hooks/exhaustive-deps
  );

  const draw = useMemo(() => {
    if (!geo) return null;
    const n = geo.refX.length;
    const k0 = Math.min((z.W - 2 * z.PAD) / Math.max(1, geo.span), (z.H - 2 * z.PAD) / Math.max(1, geo.span));
    // Phone GPS lines often sit 1–3 m apart, which is under a pixel at this scale.
    // Push them apart from the reference line by a stated factor so the difference is visible.
    const gapPx = geo.maxGap * k0;
    const ex = gapPx > 0 && gapPx < z.minGapPx ? Math.min(MAX_EXAGGERATION, z.minGapPx / gapPx) : 1;
    const lx = geo.laps.map((l) => Array.from({ length: n }, (_, i) => geo.refX[i] + (l.x[i] - geo.refX[i]) * ex));
    const ly = geo.laps.map((l) => Array.from({ length: n }, (_, i) => geo.refY[i] + (l.y[i] - geo.refY[i]) * ex));
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    const grow = (x: number, y: number) => {
      if (!Number.isFinite(x) || !Number.isFinite(y)) return;
      x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
    };
    for (let i = 0; i < n; i++) { grow(geo.refX[i], geo.refY[i]); lx.forEach((xs, j) => grow(xs[i], ly[j][i])); }
    const k = Math.min((z.W - 2 * z.PAD) / Math.max(1, x1 - x0), (z.H - 2 * z.PAD) / Math.max(1, y1 - y0));
    const ox = (z.W - (x1 - x0) * k) / 2, oy = (z.H - (y1 - y0) * k) / 2;
    const P = (x: number, y: number): [number, number] => [ox + (x - x0) * k, z.H - (oy + (y - y0) * k)];
    const pathOf = (xs: ArrayLike<number>, ys: ArrayLike<number>) => {
      let d = '', pen = false;
      for (let i = 0; i < n; i++) {
        if (!Number.isFinite(xs[i]) || !Number.isFinite(ys[i])) { pen = false; continue; }
        const [px, py] = P(xs[i], ys[i]);
        d += `${pen ? 'L' : 'M'}${px.toFixed(1)},${py.toFixed(1)}`;
        pen = true;
      }
      return d;
    };
    const pointAt = (j: number, i: number | null) => (i == null || !Number.isFinite(lx[j][i]) ? null : P(lx[j][i], ly[j][i]));
    const start = P(geo.refX[0], geo.refY[0]);
    return {
      ex, start,
      track: pathOf(geo.refX, geo.refY),
      lines: geo.laps.map((_, j) => pathOf(lx[j], ly[j])),
      marks: geo.laps.map((l, j) => ({ brake: pointAt(j, l.brake), slowest: pointAt(j, l.slowest), throttle: pointAt(j, l.throttle) })),
      /** Position of lap j after `sec` seconds into the window. */
      at(j: number, sec: number) {
        const t = geo.laps[j].t;
        let i = 0;
        while (i < n - 1 && !(t[i + 1] > sec)) i++;
        return pointAt(j, i);
      },
      duration: Math.max(...geo.laps.map((l) => { for (let i = n - 1; i >= 0; i--) if (Number.isFinite(l.t[i])) return l.t[i]; return 0; })),
    };
  }, [geo, z]);

  const reduced = typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  const animate = variant === 'full' && !reduced && !!draw && draw.duration > 0;
  const [clock, setClock] = useState(0);
  useEffect(() => {
    if (!animate || !draw) return;
    // Real time, with a short pause on the last frame before the replay restarts.
    const loop = draw.duration + 1.2;
    let raf = 0; const t0 = performance.now();
    const tick = (now: number) => { setClock(Math.min(draw.duration, ((now - t0) / 1000) % loop)); raf = requestAnimationFrame(tick); };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [animate, draw]);

  if (!geo || !draw) return null;
  const full = variant === 'full';
  return (
    <svg viewBox={`0 0 ${z.W} ${z.H}`} className={`cl cl-${variant}`} role="img" aria-label={label}>
      <path d={draw.track} className="cl-track" style={{ strokeWidth: z.band }} />
      {full && <text x={draw.start[0]} y={draw.start[1] - z.band / 2 - 4} className="cl-entry">in</text>}
      {/* comparison underneath, coached lap on top */}
      {draw.lines.map((d, j) => ({ d, j })).reverse().map(({ d, j }) => (
        <path key={j} d={d} className={`cl-line ${ROLE[j]}`} style={{ strokeWidth: z.line }} />
      ))}
      {draw.marks.map((m, j) => (
        <g key={j} className={ROLE[j]}>
          {full && m.brake && <circle cx={m.brake[0]} cy={m.brake[1]} r="4.5" className="cl-mk" />}
          {m.slowest && <rect x={m.slowest[0] - (full ? 4.5 : 3)} y={m.slowest[1] - (full ? 4.5 : 3)} width={full ? 9 : 6} height={full ? 9 : 6} transform={`rotate(45 ${m.slowest[0]} ${m.slowest[1]})`} className="cl-mk" />}
          {full && m.throttle && <path d={`M${m.throttle[0]},${m.throttle[1] - 5.5}L${m.throttle[0] + 5},${m.throttle[1] + 3.5}L${m.throttle[0] - 5},${m.throttle[1] + 3.5}Z`} className="cl-mk" />}
        </g>
      ))}
      {animate && draw.lines.map((_, j) => {
        const p = draw.at(j, clock);
        return p && <circle key={j} cx={p[0]} cy={p[1]} r="5.5" className={`cl-dot ${ROLE[j]}`} />;
      })}
      {full && draw.ex > 1.05 && (
        <text x={z.W - 6} y={z.H - 6} className="cl-note" textAnchor="end">gap between lines drawn ×{draw.ex.toFixed(1)}</text>
      )}
    </svg>
  );
}
