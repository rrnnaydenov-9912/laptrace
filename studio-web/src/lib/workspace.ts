// The comparison workspace: everything derived from "reference lap + laps of interest".

import { alignToReference, projectorFor, resampleLap, type AlignedLap, type ResampledLap } from './alignment';
import { cornerStats, detectCorners, type Corner, type CornerStats } from './corners';
import type { Projector } from './geo';
import type { LapData } from './types';

export interface Workspace {
  refKey: string;
  refLap: LapData;
  ref: ResampledLap;
  proj: Projector;
  aligned: Map<string, AlignedLap>;
  corners: Corner[];
  stats: Map<string, CornerStats[]>;
}

// Alignment is the expensive step; keep results while the reference is unchanged.
let cacheRef = '';
let cache = new Map<string, AlignedLap>();
let cacheResampled: { key: string; ref: ResampledLap; proj: Projector; corners: Corner[] } | null = null;

export function buildWorkspace(refLap: LapData, laps: LapData[]): Workspace {
  if (cacheRef !== refLap.key || !cacheResampled) {
    cacheRef = refLap.key;
    cache = new Map();
    const proj = projectorFor(refLap);
    const ref = resampleLap(refLap, proj);
    cacheResampled = { key: refLap.key, ref, proj, corners: detectCorners(ref) };
  }
  const { ref, proj, corners } = cacheResampled;
  const aligned = new Map<string, AlignedLap>();
  const refAligned = cache.get(refLap.key) ?? alignToReference(ref, ref);
  cache.set(refLap.key, refAligned);
  aligned.set(refLap.key, refAligned);
  for (const lap of laps) {
    if (aligned.has(lap.key) || lap.t.length < 2) continue;
    let a = cache.get(lap.key);
    if (!a) {
      a = alignToReference(resampleLap(lap, proj), ref);
      cache.set(lap.key, a);
    }
    aligned.set(lap.key, a);
  }
  const stats = new Map<string, CornerStats[]>();
  for (const [key, a] of aligned) stats.set(key, corners.map((c) => cornerStats(a, refAligned, c)));
  return { refKey: refLap.key, refLap, ref, proj, aligned, corners, stats };
}

/** Nearest reference-grid distance to a map position, or null if far from the line. */
export function nearestS(ws: Workspace, lat: number, lon: number, maxM = 60): number | null {
  const x = ws.proj.x(lat, lon);
  const y = ws.proj.y(lat);
  let best = -1;
  let bestD = maxM * maxM;
  const { x: rx, y: ry } = ws.ref;
  for (let i = 0; i < rx.length; i++) {
    const dx = rx[i] - x;
    const dy = ry[i] - y;
    const d = dx * dx + dy * dy;
    if (d < bestD) { bestD = d; best = i; }
  }
  return best < 0 ? null : ws.ref.s[best];
}

/** Position of a lap at elapsed time `time` (for playback ghosts). */
export function positionAtTime(lap: LapData, time: number): [number, number] | null {
  const t = lap.t;
  const n = t.length;
  if (n < 2 || time < 0 || time > t[n - 1]) return null;
  let lo = 0;
  let hi = n - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (t[mid] <= time) lo = mid; else hi = mid;
  }
  const f = (time - t[lo]) / (t[hi] - t[lo] || 1);
  return [lap.lat[lo] + (lap.lat[hi] - lap.lat[lo]) * f, lap.lon[lo] + (lap.lon[hi] - lap.lon[lo]) * f];
}
