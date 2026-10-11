// Directed timing-gate crossing detection with interpolated crossing times.

import { angleDiff, makeProjector, segmentIntersection, xyBearing } from './geo';
import type { Gate } from './types';

export interface Crossing {
  /** Fractional sample position (index + fraction toward the next sample). */
  p: number;
  /** Interpolated crossing time, seconds. */
  time: number;
}

export interface CrossingOptions {
  /** Extend the gate by this many metres at each end (GPS tolerance). */
  extendM?: number;
  /** Ignore a crossing that follows the previous one within this many seconds. */
  debounceS?: number;
  from?: number;
  to?: number;
}

export function findCrossings(
  t: ArrayLike<number>,
  lat: ArrayLike<number>,
  lon: ArrayLike<number>,
  gate: Gate,
  opts: CrossingOptions = {},
): Crossing[] {
  const extend = opts.extendM ?? 10;
  const debounce = opts.debounceS ?? 10;
  const n = t.length;
  const from = Math.max(0, Math.floor(opts.from ?? 0));
  const to = Math.min(n - 1, Math.ceil(opts.to ?? n - 1));

  const midLat = (gate.start.lat + gate.end.lat) / 2;
  const midLon = (gate.start.lon + gate.end.lon) / 2;
  const proj = makeProjector(midLat, midLon);
  let ax = proj.x(gate.start.lat, gate.start.lon);
  let ay = proj.y(gate.start.lat);
  let bx = proj.x(gate.end.lat, gate.end.lon);
  let by = proj.y(gate.end.lat);
  const gl = Math.hypot(bx - ax, by - ay) || 1;
  const ux = (bx - ax) / gl;
  const uy = (by - ay) / gl;
  ax -= ux * extend;
  ay -= uy * extend;
  bx += ux * extend;
  by += uy * extend;
  const reach = gl / 2 + extend + 150; // only test segments near the gate

  const out: Crossing[] = [];
  let px = proj.x(lat[from], lon[from]);
  let py = proj.y(lat[from]);
  for (let i = from; i < to; i++) {
    const qx = proj.x(lat[i + 1], lon[i + 1]);
    const qy = proj.y(lat[i + 1]);
    if (Math.hypot(px, py) < reach || Math.hypot(qx, qy) < reach) {
      const hit = segmentIntersection(px, py, qx, qy, ax, ay, bx, by);
      if (hit && (qx !== px || qy !== py)) {
        const dir = xyBearing(qx - px, qy - py);
        if (Math.abs(angleDiff(dir, gate.travelBearing)) <= 90) {
          const time = t[i] + hit.u * (t[i + 1] - t[i]);
          const last = out[out.length - 1];
          if (!last || time - last.time >= debounce) out.push({ p: i + hit.u, time });
        }
      }
    }
    px = qx;
    py = qy;
  }
  return out;
}

/** Linear interpolation of an array at a fractional position. */
export function valueAt(arr: ArrayLike<number>, p: number): number {
  const i = Math.floor(p);
  const f = p - i;
  if (i >= arr.length - 1) return arr[arr.length - 1];
  if (i < 0) return arr[0];
  return f === 0 ? arr[i] : arr[i] + (arr[i + 1] - arr[i]) * f;
}
