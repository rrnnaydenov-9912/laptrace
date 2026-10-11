// Distance-domain alignment: resample laps to a 1 m grid and project them onto
// the reference lap's path so channels line up by track position, not by each
// lap's own (drifting) odometer.

import { makeProjector, type Projector } from './geo';
import type { LapData } from './types';

export interface ResampledLap {
  key: string;
  /** Distance grid along this lap's own path, metres. */
  s: Float64Array;
  t: Float64Array;
  speed: Float32Array;
  gLong: Float32Array | null;
  gLat: Float32Array | null;
  lat: Float64Array;
  lon: Float64Array;
  x: Float64Array;
  y: Float64Array;
  length: number;
}

/** Channels of one lap expressed on the reference lap's distance grid. NaN = no coverage. */
export interface AlignedLap {
  key: string;
  t: Float64Array;
  speed: Float32Array;
  gLong: Float32Array | null;
  gLat: Float32Array | null;
  lat: Float64Array;
  lon: Float64Array;
  /** Time delta vs the reference at each grid point, seconds (positive = slower). */
  delta: Float64Array;
  /** Lateral offset from the reference path, metres (diagnostic). */
  offset: Float32Array;
}

export function projectorFor(lap: LapData): Projector {
  const k = lap.lat.length >> 1;
  return makeProjector(lap.lat[k] ?? 0, lap.lon[k] ?? 0);
}

export function resampleLap(lap: LapData, proj: Projector, step = 1): ResampledLap {
  const len = lap.length;
  const m = Math.max(2, Math.floor(len / step) + 1);
  const s = new Float64Array(m);
  const t = new Float64Array(m);
  const speed = new Float32Array(m);
  const gLong = lap.gLong ? new Float32Array(m) : null;
  const gLat = lap.gLat ? new Float32Array(m) : null;
  const lat = new Float64Array(m);
  const lon = new Float64Array(m);
  const x = new Float64Array(m);
  const y = new Float64Array(m);
  const d = lap.dist;
  let j = 0;
  for (let i = 0; i < m; i++) {
    const si = Math.min(i * step, len);
    s[i] = si;
    while (j < d.length - 2 && d[j + 1] < si) j++;
    const span = d[j + 1] - d[j];
    const f = span > 0 ? Math.min(1, Math.max(0, (si - d[j]) / span)) : 0;
    const lerp = (a: ArrayLike<number>) => a[j] + (a[j + 1] - a[j]) * f;
    t[i] = lerp(lap.t);
    speed[i] = lerp(lap.speed);
    if (gLong) gLong[i] = lerp(lap.gLong!);
    if (gLat) gLat[i] = lerp(lap.gLat!);
    lat[i] = lerp(lap.lat);
    lon[i] = lerp(lap.lon);
    x[i] = proj.x(lat[i], lon[i]);
    y[i] = proj.y(lat[i]);
  }
  return { key: lap.key, s, t, speed, gLong, gLat, lat, lon, x, y, length: len };
}

function projectOnSegment(
  px: number, py: number, ax: number, ay: number, bx: number, by: number,
): { f: number; d2: number } {
  const dx = bx - ax;
  const dy = by - ay;
  const l2 = dx * dx + dy * dy;
  let f = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0;
  f = Math.max(0, Math.min(1, f));
  const qx = ax + f * dx - px;
  const qy = ay + f * dy - py;
  return { f, d2: qx * qx + qy * qy };
}

/** Projects each point of `lap` onto `ref`, returning monotonic reference distances. */
export function projectToReference(lap: ResampledLap, ref: ResampledLap): { sRef: Float64Array; offset: Float32Array } {
  const n = lap.s.length;
  const m = ref.s.length;
  const sRef = new Float64Array(n);
  const offset = new Float32Array(n);
  let k = 0;
  let prev = 0;
  for (let i = 0; i < n; i++) {
    const lo = i === 0 ? 0 : Math.max(0, k - 20);
    const hi = i === 0 ? Math.max(2, Math.floor(m * 0.1)) : Math.min(m - 1, k + 60);
    let best = { seg: k, f: 0, d2: Infinity };
    for (let j = lo; j < Math.min(hi, m - 1); j++) {
      const r = projectOnSegment(lap.x[i], lap.y[i], ref.x[j], ref.y[j], ref.x[j + 1], ref.y[j + 1]);
      if (r.d2 < best.d2) best = { seg: j, f: r.f, d2: r.d2 };
    }
    // Lost the line (big GPS error or a different route): widen the search ahead.
    if (best.d2 > 30 * 30 && i > 0) {
      for (let j = Math.min(hi, m - 1); j < Math.min(m - 1, k + 400); j++) {
        const r = projectOnSegment(lap.x[i], lap.y[i], ref.x[j], ref.y[j], ref.x[j + 1], ref.y[j + 1]);
        if (r.d2 < best.d2) best = { seg: j, f: r.f, d2: r.d2 };
      }
    }
    const s = ref.s[best.seg] + best.f * (ref.s[best.seg + 1] - ref.s[best.seg]);
    const sm = i === 0 ? s : Math.max(prev, s);
    sRef[i] = sm;
    offset[i] = Math.sqrt(best.d2);
    prev = sm;
    k = best.seg;
  }
  return { sRef, offset };
}

/** Express `lap` on the reference grid (1 m spacing). */
export function alignToReference(lap: ResampledLap, ref: ResampledLap): AlignedLap {
  const m = ref.s.length;
  const t = new Float64Array(m).fill(NaN);
  const speed = new Float32Array(m).fill(NaN);
  const gLong = lap.gLong ? new Float32Array(m).fill(NaN) : null;
  const gLat = lap.gLat ? new Float32Array(m).fill(NaN) : null;
  const lat = new Float64Array(m).fill(NaN);
  const lon = new Float64Array(m).fill(NaN);
  const delta = new Float64Array(m).fill(NaN);
  const offset = new Float32Array(m).fill(NaN);

  if (lap.key === ref.key) {
    t.set(ref.t);
    speed.set(ref.speed);
    if (gLong && ref.gLong) gLong.set(ref.gLong);
    if (gLat && ref.gLat) gLat.set(ref.gLat);
    lat.set(ref.lat);
    lon.set(ref.lon);
    delta.fill(0);
    offset.fill(0);
    return { key: lap.key, t, speed, gLong, gLat, lat, lon, delta, offset };
  }

  const { sRef, offset: off } = projectToReference(lap, ref);
  const n = sRef.length;
  // Lap start sits on the reference start line by construction; anchor it at 0.
  const sStart = sRef[0] < 15 ? 0 : sRef[0];
  let j = 0;
  for (let g = 0; g < m; g++) {
    const s = ref.s[g];
    if (s < sStart || s > sRef[n - 1]) continue;
    while (j < n - 2 && sRef[j + 1] < s) j++;
    const a = s < sRef[0] ? 0 : j;
    const span = sRef[a + 1] - sRef[a];
    const f = span > 0 ? Math.min(1, Math.max(0, (s - sRef[a]) / span)) : 0;
    const lerp = (arr: ArrayLike<number>) => arr[a] + (arr[a + 1] - arr[a]) * f;
    t[g] = lerp(lap.t);
    speed[g] = lerp(lap.speed);
    if (gLong) gLong[g] = lerp(lap.gLong!);
    if (gLat) gLat[g] = lerp(lap.gLat!);
    lat[g] = lerp(lap.lat);
    lon[g] = lerp(lap.lon);
    offset[g] = lerp(off);
    delta[g] = t[g] - ref.t[g];
  }
  return { key: lap.key, t, speed, gLong, gLat, lat, lon, delta, offset };
}

/** Value of a grid channel at distance s (linear). */
export function sampleAt(arr: ArrayLike<number>, s: number): number {
  const i = Math.floor(s);
  if (i < 0) return arr[0];
  if (i >= arr.length - 1) return arr[arr.length - 1];
  return arr[i] + (arr[i + 1] - arr[i]) * (s - i);
}

/** Distance on the reference grid at which elapsed reference time reaches `time`. */
export function distanceAtTime(ref: ResampledLap, time: number): number {
  const t = ref.t;
  let lo = 0;
  let hi = t.length - 1;
  if (time <= t[0]) return 0;
  if (time >= t[hi]) return ref.s[hi];
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (t[mid] < time) lo = mid; else hi = mid;
  }
  const f = (time - t[lo]) / (t[hi] - t[lo] || 1);
  return ref.s[lo] + f * (ref.s[hi] - ref.s[lo]);
}
