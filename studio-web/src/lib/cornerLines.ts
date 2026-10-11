// Geometry for comparing two laps' lines through one corner.
// Every lap is already aligned to the reference distance grid, so index i is the same
// place on track for all of them: the gap between two lines at i is their lateral difference.

import type { Corner, CornerStats } from './corners';
import type { Workspace } from './workspace';

export interface LapLine {
  key: string;
  /** Projected position per window index, metres; NaN where the lap has no data. */
  x: Float64Array;
  y: Float64Array;
  /** Elapsed time from the start of the window, seconds; NaN where unknown. */
  t: Float64Array;
  stats: CornerStats | null;
  /** Window indices of the lap's own brake point, slowest point and throttle pick-up. */
  brake: number | null;
  slowest: number | null;
  throttle: number | null;
}

export interface CornerLines {
  /** First reference-grid index of the window. */
  a: number;
  /** Reference line through the window, metres. */
  refX: Float64Array;
  refY: Float64Array;
  laps: LapLine[];
  /** Largest distance between the first two laps' lines inside the corner itself, metres. */
  maxGap: number;
  /** Span of the window's bounding box, metres (longest side). */
  span: number;
}

function idxAt(s: Float64Array, v: number): number {
  let lo = 0, hi = s.length - 1;
  while (lo < hi) { const m = (lo + hi) >> 1; if (s[m] < v) lo = m + 1; else hi = m; }
  return lo;
}

const fin = (v: number | undefined | null): v is number => typeof v === 'number' && Number.isFinite(v);

export function cornerLines(ws: Workspace, corner: Corner, keys: string[]): CornerLines | null {
  const s = ws.ref.s;
  const stats = keys.map((k) => ws.stats.get(k)?.find((c) => c.corner === corner.number) ?? null);
  const brakes = stats.map((st) => st?.brakeS).filter(fin);
  const throttles = stats.map((st) => st?.throttleS).filter(fin);
  const from = Math.max(corner.zoneStart, Math.min(corner.sStart, ...brakes) - 30);
  const to = Math.min(corner.zoneEnd, Math.max(corner.sEnd, ...throttles) + 50);
  const a = idxAt(s, from);
  const b = idxAt(s, to);
  const n = b - a + 1;
  if (n < 4) return null;

  const refX = ws.ref.x.slice(a, b + 1);
  const refY = ws.ref.y.slice(a, b + 1);
  const at = (v: number | undefined) => (fin(v) ? Math.min(n - 1, Math.max(0, idxAt(s, v) - a)) : null);

  const laps: LapLine[] = [];
  keys.forEach((key, li) => {
    const al = ws.aligned.get(key);
    if (!al) return;
    const x = new Float64Array(n), y = new Float64Array(n), t = new Float64Array(n);
    let t0 = NaN;
    for (let i = 0; i < n; i++) {
      const lat = al.lat[a + i], lon = al.lon[a + i], ti = al.t[a + i];
      const ok = Number.isFinite(lat) && Number.isFinite(lon);
      x[i] = ok ? ws.proj.x(lat, lon) : NaN;
      y[i] = ok ? ws.proj.y(lat) : NaN;
      if (!Number.isFinite(t0) && Number.isFinite(ti)) t0 = ti;
      t[i] = Number.isFinite(ti) ? ti - t0 : NaN;
    }
    const st = stats[li];
    laps.push({ key, x, y, t, stats: st, brake: at(st?.brakeS), slowest: at(st?.minS), throttle: at(st?.throttleS) });
  });
  if (!laps.length) return null;

  let maxGap = 0;
  if (laps.length >= 2) {
    const [p, q] = laps;
    const i0 = Math.max(0, idxAt(s, corner.sStart) - a), i1 = Math.min(n - 1, idxAt(s, corner.sEnd) - a);
    for (let i = i0; i <= i1; i++) {
      const d = Math.hypot(p.x[i] - q.x[i], p.y[i] - q.y[i]);
      if (Number.isFinite(d) && d > maxGap) maxGap = d;
    }
  }
  let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
  for (let i = 0; i < n; i++) {
    x0 = Math.min(x0, refX[i]); x1 = Math.max(x1, refX[i]); y0 = Math.min(y0, refY[i]); y1 = Math.max(y1, refY[i]);
  }
  return { a, refX, refY, laps, maxGap, span: Math.max(x1 - x0, y1 - y0) };
}

/** The lap (other than `exceptKey`) with the quickest valid zone time through a corner. */
export function fastestThrough(ws: Workspace, cornerNumber: number, exceptKey: string): string | null {
  let best: string | null = null, bestT = Infinity;
  for (const [key, list] of ws.stats) {
    if (key === exceptKey) continue;
    const st = list.find((c) => c.corner === cornerNumber);
    if (st?.valid && st.zoneTime < bestT) { bestT = st.zoneTime; best = key; }
  }
  return best;
}

/** Plain-language comparison of lap A against lap B in one corner. */
export function compareSentence(
  aStats: CornerStats, bStats: CornerStats, bLabel: string, fmtSpeedDiff: (v: number) => string,
): string {
  const dt = bStats.zoneTime - aStats.zoneTime;
  const head = Math.abs(dt) < 0.03
    ? `You and lap ${bLabel} took the same time here.`
    : dt < 0 ? `Lap ${bLabel} was ${(-dt).toFixed(2)} s quicker here.` : `You were ${dt.toFixed(2)} s quicker than lap ${bLabel} here.`;
  const who = dt < 0 ? `Lap ${bLabel}` : 'You';
  const [fast, slow] = dt < 0 ? [bStats, aStats] : [aStats, bStats];
  const bits: string[] = [];
  if (fin(fast.brakeS) && fin(slow.brakeS)) {
    const d = fast.brakeS - slow.brakeS;
    if (Math.abs(d) >= 5) bits.push(`braked ${Math.round(Math.abs(d))} m ${d > 0 ? 'later' : 'earlier'}`);
  }
  const dMin = fast.minSpeed - slow.minSpeed;
  if (Math.abs(dMin) >= 2) bits.push(`carried ${fmtSpeedDiff(Math.abs(dMin))} ${dMin > 0 ? 'more' : 'less'} at the slowest point`);
  if (fin(fast.throttleS) && fin(slow.throttleS)) {
    const d = fast.throttleS - slow.throttleS;
    if (Math.abs(d) >= 5) bits.push(`picked up the throttle ${Math.round(Math.abs(d))} m ${d < 0 ? 'sooner' : 'later'}`);
  }
  const dExit = fast.exitSpeed - slow.exitSpeed;
  if (dExit >= 2) bits.push(`left the corner ${fmtSpeedDiff(dExit)} faster`);
  if (Math.abs(dt) < 0.03 || !bits.length) return head;
  const list = bits.length > 1 ? `${bits.slice(0, -1).join(', ')} and ${bits[bits.length - 1]}` : bits[0];
  return `${head} ${who} ${list}.`;
}
