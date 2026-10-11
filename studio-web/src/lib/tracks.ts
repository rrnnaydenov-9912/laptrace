// Built-in track database and track detection.

import tracksJson from '../data/tracks.json';
import { angleDiff, bearing, haversine } from './geo';
import { findCrossings } from './gates';
import type { Channels, Gate, LatLon, TrackDef } from './types';

export const BUILTIN_TRACKS: TrackDef[] = (tracksJson as { tracks: TrackDef[] }).tracks;

/** Returns the track whose radius contains at least 60% of the session's points. */
export function detectTrack(ch: Channels, tracks: TrackDef[]): TrackDef | null {
  const n = ch.t.length;
  const step = Math.max(1, Math.floor(n / 400));
  let best: TrackDef | null = null;
  let bestShare = 0;
  for (const tr of tracks) {
    let inside = 0;
    let total = 0;
    for (let i = 0; i < n; i += step) {
      total++;
      if (haversine(ch.lat[i], ch.lon[i], tr.center.lat, tr.center.lon) <= tr.radiusMeters) inside++;
    }
    const share = total ? inside / total : 0;
    if (share >= 0.6 && share > bestShare) {
      best = tr;
      bestShare = share;
    }
  }
  return best;
}

export function startFinishGate(track: TrackDef): Gate | null {
  return track.gates.find((g) => g.id === 'sf') ?? track.gates[0] ?? null;
}

export function splitGates(track: TrackDef): Gate[] {
  const sf = startFinishGate(track);
  return track.gates.filter((g) => g !== sf);
}

/**
 * Build a start/finish gate from two clicked points. The travel direction is
 * picked as the perpendicular that the session actually crosses most often.
 */
export function gateFromPoints(a: LatLon, b: LatLon, ch: Channels): Gate {
  const lineBearing = bearing(a.lat, a.lon, b.lat, b.lon);
  const candidates = [(lineBearing + 90) % 360, (lineBearing + 270) % 360];
  let bestDir = candidates[0];
  let bestCount = -1;
  for (const dir of candidates) {
    const g: Gate = { id: 'sf', label: 'Start / Finish', start: a, end: b, travelBearing: dir };
    const count = findCrossings(ch.t, ch.lat, ch.lon, g, { extendM: 5 }).length;
    if (count > bestCount) {
      bestCount = count;
      bestDir = dir;
    }
  }
  return {
    id: 'sf',
    label: 'Start / Finish',
    start: a,
    end: b,
    travelBearing: Math.round(bestDir * 10) / 10,
  };
}

export function makeUserTrack(name: string, center: LatLon, gate: Gate): TrackDef {
  return {
    id: `user-${Date.now().toString(36)}`,
    name,
    center,
    radiusMeters: 1500,
    gates: [gate],
    userDefined: true,
  };
}

/** A gate perpendicular to the path at the given point, used for virtual sectors. */
export function perpendicularGate(id: string, label: string, p: LatLon, headingDeg: number, widthM = 40): Gate {
  const half = widthM / 2;
  const R = 6371008.8;
  const DEG = Math.PI / 180;
  const left = (headingDeg - 90) * DEG;
  const dLat = (Math.cos(left) * half) / R / DEG;
  const dLon = (Math.sin(left) * half) / (R * Math.cos(p.lat * DEG)) / DEG;
  return {
    id,
    label,
    start: { lat: p.lat + dLat, lon: p.lon + dLon },
    end: { lat: p.lat - dLat, lon: p.lon - dLon },
    travelBearing: ((headingDeg % 360) + 360) % 360,
  };
}

export function sameDirection(a: number, b: number): boolean {
  return Math.abs(angleDiff(a, b)) <= 90;
}
