// Corner detection on the reference lap and per-lap corner statistics.

import { angleDiff, xyBearing } from './geo';
import { sampleAt, type AlignedLap, type ResampledLap } from './alignment';

export interface Corner {
  number: number;
  direction: 'L' | 'R';
  /** Corner start/end/apex on the reference distance grid, metres. */
  sStart: number;
  sEnd: number;
  sApex: number;
  /** Total heading change, degrees. */
  angle: number;
  apexLat: number;
  apexLon: number;
  /** Analysis zone (straight midpoint to straight midpoint). */
  zoneStart: number;
  zoneEnd: number;
}

export interface CornerOptions {
  /** Minimum curvature, 1/m (default 1/200). */
  minCurvature?: number;
  minAngle?: number;
  minLength?: number;
  mergeGap?: number;
}

const DEG = Math.PI / 180;

function movingAverage(a: Float64Array, half: number): Float64Array {
  const n = a.length;
  const out = new Float64Array(n);
  let sum = 0;
  let cnt = 0;
  let lo = 0;
  let hi = -1;
  for (let i = 0; i < n; i++) {
    const want0 = Math.max(0, i - half);
    const want1 = Math.min(n - 1, i + half);
    while (hi < want1) { hi++; sum += a[hi]; cnt++; }
    while (lo < want0) { sum -= a[lo]; lo++; cnt--; }
    out[i] = sum / cnt;
  }
  return out;
}

/** Signed curvature (1/m, positive = right turn) along a 1 m-resampled lap. */
export function curvature(ref: ResampledLap, headingHalf = 8, smoothHalf = 7): Float64Array {
  const n = ref.s.length;
  const heading = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const a = Math.max(0, i - headingHalf);
    const b = Math.min(n - 1, i + headingHalf);
    heading[i] = xyBearing(ref.x[b] - ref.x[a], ref.y[b] - ref.y[a]);
  }
  const k = new Float64Array(n);
  for (let i = 1; i < n - 1; i++) {
    const ds = ref.s[i + 1] - ref.s[i - 1];
    k[i] = ds > 0 ? (angleDiff(heading[i + 1], heading[i - 1]) * DEG) / ds : 0;
  }
  return movingAverage(k, smoothHalf);
}

export function detectCorners(ref: ResampledLap, opts: CornerOptions = {}): Corner[] {
  const minK = opts.minCurvature ?? 1 / 200;
  const minAngle = opts.minAngle ?? 20;
  const minLength = opts.minLength ?? 10;
  const mergeGap = opts.mergeGap ?? 25;
  const n = ref.s.length;
  if (n < 50) return [];
  const k = curvature(ref);

  // Runs of same-sign curvature above the threshold.
  type Run = { a: number; b: number; sign: number };
  const runs: Run[] = [];
  for (let i = 0; i < n; i++) {
    const sign = k[i] > minK ? 1 : k[i] < -minK ? -1 : 0;
    if (sign === 0) continue;
    const last = runs[runs.length - 1];
    if (last && last.sign === sign && i - last.b <= mergeGap) last.b = i;
    else runs.push({ a: i, b: i, sign });
  }

  const corners: Corner[] = [];
  for (const r of runs) {
    let angle = 0;
    for (let i = r.a; i <= r.b; i++) angle += k[i] * (i > 0 ? ref.s[i] - ref.s[i - 1] : 0);
    angle = Math.abs(angle) / DEG;
    const len = ref.s[r.b] - ref.s[r.a];
    if (angle < minAngle || len < minLength) continue;
    // Apex = minimum speed within the corner, allowing a few metres either side.
    let apex = r.a;
    const lo = Math.max(0, r.a - 10);
    const hi = Math.min(n - 1, r.b + 10);
    for (let i = lo; i <= hi; i++) if (ref.speed[i] < ref.speed[apex]) apex = i;
    corners.push({
      number: corners.length + 1,
      direction: r.sign > 0 ? 'R' : 'L',
      sStart: ref.s[r.a],
      sEnd: ref.s[r.b],
      sApex: ref.s[apex],
      angle,
      apexLat: ref.lat[apex],
      apexLon: ref.lon[apex],
      zoneStart: 0,
      zoneEnd: ref.length,
    });
  }
  for (let i = 0; i < corners.length; i++) {
    corners[i].zoneStart = i === 0 ? 0 : (corners[i - 1].sEnd + corners[i].sStart) / 2;
    corners[i].zoneEnd = i === corners.length - 1 ? ref.s[n - 1] : (corners[i].sEnd + corners[i + 1].sStart) / 2;
  }
  return corners;
}

export interface CornerStats {
  corner: number;
  entrySpeed: number;
  minSpeed: number;
  minS: number;
  exitSpeed: number;
  timeInCorner: number;
  zoneTime: number;
  /** Where braking for the corner starts (speed peak before the apex), or NaN. */
  brakeS: number;
  /** Where speed starts rising again after the minimum (throttle pick-up), or NaN. */
  throttleS: number;
  /** Zone time minus the reference's zone time, seconds (positive = slower). */
  lossVsRef: number;
  valid: boolean;
}

function finite(arr: ArrayLike<number>, a: number, b: number): boolean {
  for (let i = Math.max(0, Math.floor(a)); i <= Math.min(arr.length - 1, Math.ceil(b)); i++) {
    if (!Number.isFinite(arr[i])) return false;
  }
  return true;
}

export function cornerStats(lap: AlignedLap, ref: AlignedLap, c: Corner): CornerStats {
  const valid = finite(lap.t, c.zoneStart, c.zoneEnd) && finite(lap.speed, c.zoneStart, c.zoneEnd);
  const sp = lap.speed;
  let minS = c.sApex;
  let minSpeed = Infinity;
  const lo = Math.max(c.zoneStart, c.sStart - 20);
  const hi = Math.min(c.zoneEnd, c.sEnd + 10);
  for (let s = Math.ceil(lo); s <= Math.floor(hi); s++) {
    if (sp[s] < minSpeed) { minSpeed = sp[s]; minS = s; }
  }
  let peakS = c.zoneStart;
  let peak = -Infinity;
  for (let s = Math.ceil(c.zoneStart); s <= Math.floor(minS); s++) {
    if (sp[s] > peak) { peak = sp[s]; peakS = s; }
  }
  const brakeS = peak - minSpeed > 5 ? peakS : NaN;
  let throttleS = NaN;
  for (let s = Math.ceil(minS); s <= Math.floor(c.zoneEnd); s++) {
    if (sp[s] > minSpeed + 2) { throttleS = s; break; }
  }
  const zoneTime = sampleAt(lap.t, c.zoneEnd) - sampleAt(lap.t, c.zoneStart);
  const refZone = sampleAt(ref.t, c.zoneEnd) - sampleAt(ref.t, c.zoneStart);
  return {
    corner: c.number,
    entrySpeed: sampleAt(sp, c.sStart),
    minSpeed: Number.isFinite(minSpeed) ? minSpeed : NaN,
    minS,
    exitSpeed: sampleAt(sp, c.sEnd),
    timeInCorner: sampleAt(lap.t, c.sEnd) - sampleAt(lap.t, c.sStart),
    zoneTime,
    brakeS,
    throttleS,
    lossVsRef: zoneTime - refZone,
    valid,
  };
}
