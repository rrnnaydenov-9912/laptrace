import { describe, expect, it } from 'vitest';
import { findCrossings } from '../gates';
import { lapsFromCrossings } from '../laps';
import type { Gate } from '../types';

// A gate across a north-south road at lat 42.0, travel direction north.
const gate: Gate = {
  id: 'sf', label: 'SF',
  start: { lat: 42.0, lon: 23.0 - 0.0002 },
  end: { lat: 42.0, lon: 23.0 + 0.0002 },
  travelBearing: 0,
};

function northbound(lat0: number, n: number, dLat: number, t0 = 0) {
  const t: number[] = [], lat: number[] = [], lon: number[] = [];
  for (let i = 0; i < n; i++) { t.push(t0 + i); lat.push(lat0 + i * dLat); lon.push(23.0); }
  return { t, lat, lon };
}

describe('findCrossings', () => {
  it('interpolates the crossing time between samples', () => {
    // 1 s samples; lat steps of 0.0001 (~11 m). Gate at 42.0 sits 25% into sample 4→5.
    const p = northbound(42.0 - 0.000425, 10, 0.0001);
    const cs = findCrossings(p.t, p.lat, p.lon, gate);
    expect(cs).toHaveLength(1);
    expect(cs[0].time).toBeCloseTo(4.25, 3);
    expect(cs[0].p).toBeCloseTo(4.25, 3);
  });

  it('ignores crossings in the wrong direction', () => {
    const p = northbound(42.0 + 0.0005, 10, -0.0001);
    expect(findCrossings(p.t, p.lat, p.lon, gate)).toHaveLength(0);
  });

  it('accepts a slightly offset path within the tolerance and debounces', () => {
    const t = [0, 1, 2, 3, 4];
    const lat = [41.9999, 42.0001, 41.9999, 42.0001, 42.0002];
    const lon = [23.00028, 23.00028, 23.00028, 23.00028, 23.00028];
    // Out of the 0.0002° (≈16.5 m) half-width but within +10 m tolerance; the
    // back-and-forth second crossing at t≈2.5 comes too soon and is debounced.
    const cs = findCrossings(t, lat, lon, gate);
    expect(cs).toHaveLength(1);
    expect(cs[0].time).toBeCloseTo(0.5, 3);
  });

  it('builds Out / timed / In laps from crossings', () => {
    const laps = lapsFromCrossings([{ p: 10.5, time: 10.5 }, { p: 70, time: 70 }, { p: 131, time: 131 }], 200);
    expect(laps.map((l) => l.kind)).toEqual(['out', 'timed', 'timed', 'in']);
    expect(laps[1].pEnd - laps[1].pStart).toBeCloseTo(59.5, 6);
  });
});
