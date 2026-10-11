// Drive mode: a road drive with no laps. Stats over the whole recording.

import { haversine } from './geo';
import type { Channels, SessionAnalysis, SessionRecord } from './types';

/** Below this speed (km/h) the car counts as stopped. */
const MOVING_KMH = 5;

/** A drive is flagged by the logger (`Mode,Drive`), or is any recording with no track and no laps. */
export function isDrive(rec: Pick<SessionRecord, 'meta'>, a: Pick<SessionAnalysis, 'track' | 'lapSource'>): boolean {
  const mode = rec.meta.Mode?.trim().toLowerCase();
  if (mode === 'drive') return true;
  if (mode === 'track') return false;
  return !a.track && a.lapSource === 'single';
}

export interface DriveStats {
  distance: number;
  duration: number;
  movingTime: number;
  maxSpeed: number;
  avgMovingSpeed: number;
  /** Peak |lateral g|, braking g (positive number) and acceleration g; null without g data. */
  maxLatG: number | null;
  maxBrakeG: number | null;
  maxAccelG: number | null;
  /** Sample index of the top speed. */
  topSpeedIndex: number;
}

export function driveStats(ch: Channels): DriveStats {
  const n = ch.t.length;
  let distance = 0, movingTime = 0, movingDist = 0, maxSpeed = 0, topSpeedIndex = 0;
  for (let i = 0; i < n; i++) {
    if (ch.speed[i] > maxSpeed) { maxSpeed = ch.speed[i]; topSpeedIndex = i; }
    if (i === 0) continue;
    const d = haversine(ch.lat[i - 1], ch.lon[i - 1], ch.lat[i], ch.lon[i]);
    const dt = ch.t[i] - ch.t[i - 1];
    distance += d;
    if (ch.speed[i] >= MOVING_KMH && dt > 0 && dt < 5) { movingTime += dt; movingDist += d; }
  }
  const peak = (a: Float32Array | null, f: (v: number) => number) => {
    if (!a) return null;
    let m = 0;
    for (let i = 0; i < a.length; i++) { const v = f(a[i]); if (Number.isFinite(v) && v > m) m = v; }
    return m;
  };
  return {
    distance,
    duration: n > 1 ? ch.t[n - 1] - ch.t[0] : 0,
    movingTime,
    maxSpeed,
    avgMovingSpeed: movingTime > 0 ? (movingDist / movingTime) * 3.6 : 0,
    maxLatG: peak(ch.gLat, Math.abs),
    maxBrakeG: peak(ch.gLong, (v) => -v),
    maxAccelG: peak(ch.gLong, (v) => v),
    topSpeedIndex,
  };
}
