// Session analysis: lap segmentation, lap slicing, sectors and summary statistics.

import { bearing, haversine, median } from './geo';
import { findCrossings, valueAt } from './gates';
import { lapsFromCrossings, lapsFromLabels, singleRun } from './laps';
import { detectTrack, perpendicularGate, splitGates, startFinishGate } from './tracks';
import type {
  Channels, Gate, LapData, LapRange, LapSource, SectorSource, SessionAnalysis, SessionRecord,
  SessionSummary, TrackDef,
} from './types';

function sliceLap(ch: Channels, r: LapRange, sessionId: string, index: number): LapData {
  const idx: number[] = [];
  const first = Math.ceil(r.pStart);
  const last = Math.floor(r.pEnd);
  const pts: number[] = [];
  if (first > r.pStart) pts.push(r.pStart);
  for (let i = first; i <= last; i++) pts.push(i);
  if (r.pEnd > last) pts.push(r.pEnd);
  for (const p of pts) idx.push(p);

  const m = idx.length;
  const t = new Float64Array(m);
  const lat = new Float64Array(m);
  const lon = new Float64Array(m);
  const speed = new Float32Array(m);
  const gLong = ch.gLong ? new Float32Array(m) : null;
  const gLat = ch.gLat ? new Float32Array(m) : null;
  const dist = new Float64Array(m);
  const t0 = valueAt(ch.t, r.pStart);
  let maxSpeed = 0;
  let minSpeed = Infinity;
  for (let k = 0; k < m; k++) {
    const p = idx[k];
    t[k] = valueAt(ch.t, p) - t0;
    lat[k] = valueAt(ch.lat, p);
    lon[k] = valueAt(ch.lon, p);
    speed[k] = valueAt(ch.speed, p);
    if (gLong) gLong[k] = valueAt(ch.gLong!, p);
    if (gLat) gLat[k] = valueAt(ch.gLat!, p);
    if (k > 0) dist[k] = dist[k - 1] + haversine(lat[k - 1], lon[k - 1], lat[k], lon[k]);
    if (speed[k] > maxSpeed) maxSpeed = speed[k];
    if (speed[k] < minSpeed) minSpeed = speed[k];
  }
  return {
    key: `${sessionId}:${index}`,
    sessionId,
    index,
    label: r.label,
    kind: r.kind,
    number: r.number,
    startTime: t0,
    time: m > 1 ? t[m - 1] : 0,
    t, lat, lon, speed, gLong, gLat, dist,
    length: m > 1 ? dist[m - 1] : 0,
    maxSpeed,
    minSpeed: Number.isFinite(minSpeed) ? minSpeed : 0,
    sectors: null,
  };
}

/** Sector times for a lap: one crossing of each split gate, in path order. */
function lapSectors(ch: Channels, r: LapRange, gates: Gate[]): number[] | null {
  if (gates.length === 0) return null;
  const times: number[] = [];
  for (const g of gates) {
    const cs = findCrossings(ch.t, ch.lat, ch.lon, g, { from: r.pStart, to: r.pEnd, debounceS: 5 })
      .filter((c) => c.p > r.pStart && c.p < r.pEnd);
    if (cs.length === 0) return null;
    times.push(cs[0].time);
  }
  const t0 = valueAt(ch.t, r.pStart);
  const t1 = valueAt(ch.t, r.pEnd);
  const sorted = [t0, ...times.sort((a, b) => a - b), t1];
  const out: number[] = [];
  for (let i = 1; i < sorted.length; i++) out.push(sorted[i] - sorted[i - 1]);
  return out;
}

/** Virtual split gates at 1/3 and 2/3 of a lap's distance, perpendicular to the path. */
function virtualGates(lap: LapData): Gate[] {
  const gates: Gate[] = [];
  for (const frac of [1 / 3, 2 / 3]) {
    const target = lap.length * frac;
    let k = 1;
    while (k < lap.dist.length - 1 && lap.dist[k] < target) k++;
    let a = k - 1;
    let b = k;
    while (a > 0 && lap.dist[k] - lap.dist[a] < 8) a--;
    while (b < lap.dist.length - 1 && lap.dist[b] - lap.dist[k] < 8) b++;
    const heading = bearing(lap.lat[a], lap.lon[a], lap.lat[b], lap.lon[b]);
    gates.push(perpendicularGate(`v${gates.length + 1}`, `Split ${gates.length + 1}`, { lat: lap.lat[k], lon: lap.lon[k] }, heading));
  }
  return gates;
}

export function sessionCenter(ch: Channels): { lat: number; lon: number } {
  const step = Math.max(1, Math.floor(ch.t.length / 1000));
  const la: number[] = [];
  const lo: number[] = [];
  for (let i = 0; i < ch.t.length; i += step) { la.push(ch.lat[i]); lo.push(ch.lon[i]); }
  return { lat: median(la), lon: median(lo) };
}

export function analyzeSession(rec: SessionRecord, tracks: TrackDef[]): SessionAnalysis {
  const ch = rec.channels;
  const n = ch.t.length;
  const center = sessionCenter(ch);
  const track = detectTrack(ch, tracks);

  let ranges: LapRange[] | null = null;
  let lapSource: LapSource = 'single';
  let startFinish: Gate | null = rec.customGate;
  let sectorGates: Gate[] = [];
  let sectorSource: SectorSource = 'none';

  if (!startFinish && track) startFinish = startFinishGate(track);
  if (startFinish) {
    const cs = findCrossings(ch.t, ch.lat, ch.lon, startFinish);
    const r = lapsFromCrossings(cs, n);
    if (r.some((l) => l.kind === 'timed')) {
      ranges = r;
      lapSource = rec.customGate || track?.userDefined ? 'custom-gate' : 'track-gates';
    }
  }
  if (!ranges && ch.lap) {
    ranges = lapsFromLabels(ch.lap);
    lapSource = 'csv';
  }
  if (!ranges || ranges.length === 0) {
    ranges = singleRun(n);
    lapSource = 'single';
  }

  const laps = ranges.map((r, i) => sliceLap(ch, r, rec.id, i));
  const timed = laps.filter((l) => l.kind === 'timed' && l.time > 0);
  let bestLapIndex: number | null = null;
  for (const l of timed) {
    if (bestLapIndex == null || l.time < laps[bestLapIndex].time) bestLapIndex = l.index;
  }

  // Sectors.
  if (track && lapSource === 'track-gates' && splitGates(track).length > 0) {
    sectorGates = splitGates(track);
    sectorSource = 'track';
  } else if (bestLapIndex != null && timed.length >= 1 && laps[bestLapIndex].length > 600) {
    sectorGates = virtualGates(laps[bestLapIndex]);
    sectorSource = 'virtual';
  }
  if (sectorGates.length) {
    for (const lap of laps) {
      if (lap.kind === 'timed') lap.sectors = lapSectors(ch, ranges[lap.index], sectorGates);
    }
    const nSec = sectorGates.length + 1;
    const withSectors = timed.filter((l) => l.sectors && l.sectors.length === nSec);
    if (withSectors.length === 0) sectorSource = 'none';
  }

  let bestSectors: number[] | null = null;
  let theoreticalBest: number | null = null;
  if (sectorSource !== 'none') {
    const nSec = sectorGates.length + 1;
    const valid = timed.filter((l) => l.sectors && l.sectors.length === nSec);
    if (valid.length) {
      bestSectors = Array.from({ length: nSec }, (_, k) => Math.min(...valid.map((l) => l.sectors![k])));
      theoreticalBest = bestSectors.reduce((a, b) => a + b, 0);
    }
  }

  // GPS quality.
  const duration = n > 1 ? ch.t[n - 1] - ch.t[0] : 0;
  let gpsHz = rec.report.sampleRateHz;
  let interpolated = false;
  if (ch.fix) {
    let fixes = 0;
    for (let i = 0; i < n; i++) fixes += ch.fix[i];
    interpolated = fixes < n;
    if (duration > 0) gpsHz = fixes / duration;
  }
  const format = Object.entries(rec.meta).find(([k]) => k.toLowerCase() === 'format')?.[1] ?? '';
  const phone = /phone/i.test(format);
  if (phone && !ch.fix) gpsHz = Math.min(gpsHz, 1);
  const lowRateGps = interpolated || gpsHz <= 2.5 || phone;

  return {
    sessionId: rec.id,
    laps,
    bestLapIndex,
    theoreticalBest,
    bestSectors,
    sectorSource,
    sectorGates,
    startFinish: lapSource === 'track-gates' || lapSource === 'custom-gate' ? startFinish : null,
    lapSource,
    track,
    hasG: !!(ch.gLong || ch.gLat),
    lowRateGps,
    gpsHz,
    center,
  };
}

export function summarize(rec: SessionRecord, a: SessionAnalysis): SessionSummary {
  const n = rec.channels.t.length;
  return {
    id: rec.id,
    name: rec.name,
    fileName: rec.fileName,
    importedAt: rec.importedAt,
    date: rec.date,
    trackId: a.track?.id ?? null,
    trackName: a.track?.name ?? null,
    bestLap: a.bestLapIndex != null ? a.laps[a.bestLapIndex].time : null,
    timedLaps: a.laps.filter((l) => l.kind === 'timed').length,
    durationS: n > 1 ? rec.channels.t[n - 1] - rec.channels.t[0] : 0,
    center: a.center,
  };
}
