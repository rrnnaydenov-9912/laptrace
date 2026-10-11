import { describe, expect, it } from 'vitest';
import { alignToReference, resampleLap } from '../alignment';
import { haversine, makeProjector } from '../geo';
import type { LapData } from '../types';

const R = 200; // circle radius, metres
const lat0 = 42.0;
const lon0 = 23.0;
const proj = makeProjector(lat0, lon0);

/** A lap around a circle, driven at a given speed profile; optional lateral offset (m). */
function circleLap(key: string, speedMs: (s: number) => number, offset = 0, hz = 10): LapData {
  const circ = 2 * Math.PI * R;
  const t: number[] = [], lat: number[] = [], lon: number[] = [], speed: number[] = [];
  let s = 0, time = 0;
  while (s <= circ) {
    const ang = s / R;
    const r = R + offset;
    const x = r * Math.sin(ang), y = r * Math.cos(ang) - R; // start at (0,0), heading east
    t.push(time); lat.push(proj.lat(y)); lon.push(proj.lon(x)); speed.push(speedMs(s) * 3.6);
    const v = speedMs(s);
    s += (v / hz) * (R / r); // advance along the reference arc
    time += 1 / hz;
  }
  const dist = new Float64Array(t.length);
  for (let i = 1; i < t.length; i++) dist[i] = dist[i - 1] + haversine(lat[i - 1], lon[i - 1], lat[i], lon[i]);
  return {
    key, sessionId: 's', index: 0, label: key, kind: 'timed', number: 1, startTime: 0,
    time: t[t.length - 1], t: Float64Array.from(t), lat: Float64Array.from(lat), lon: Float64Array.from(lon),
    speed: Float32Array.from(speed), gLong: null, gLat: null, dist, length: dist[dist.length - 1],
    maxSpeed: Math.max(...speed), minSpeed: Math.min(...speed), sectors: null,
  };
}

describe('distance alignment', () => {
  it('resamples to a 1 m grid', () => {
    const lap = circleLap('a', () => 30);
    const rs = resampleLap(lap, proj);
    expect(rs.s[1] - rs.s[0]).toBe(1);
    expect(rs.s.length).toBe(Math.floor(lap.length) + 1);
    expect(rs.t[100]).toBeCloseTo(100 / 30, 1);
  });

  it('aligns a wider line onto the reference without drift', () => {
    const ref = resampleLap(circleLap('ref', () => 30), proj);
    // 3 m wider line: its own odometer runs 1.5% long; projection must remove that.
    const wide = resampleLap(circleLap('wide', () => 30, 3), proj);
    const al = alignToReference(wide, ref);
    const mid = Math.floor(ref.s.length / 2);
    // The wider line is 1.5% longer at equal speed, so it loses time in
    // proportion: delta = tRef * 3/200. A naive odometer match would instead
    // show ~0 and misplace the lap by ~19 m at the end.
    const end = ref.s.length - 20;
    expect(al.delta[mid]).toBeCloseTo(ref.t[mid] * 3 / 200, 1);
    expect(al.delta[end]).toBeCloseTo(ref.t[end] * 3 / 200, 1);
    expect(al.offset[mid]).toBeCloseTo(3, 0);
  });

  it('measures a time delta from a slower section', () => {
    const ref = resampleLap(circleLap('ref', () => 30), proj);
    // 20 m/s instead of 30 m/s over the first 300 m: +5 s at 300 m.
    const slow = resampleLap(circleLap('slow', (s) => (s < 300 ? 20 : 30)), proj);
    const al = alignToReference(slow, ref);
    expect(al.delta[150]).toBeCloseTo(150 / 20 - 150 / 30, 0);
    expect(al.delta[600]).toBeCloseTo(300 / 20 - 300 / 30, 0);
    expect(al.speed[600]).toBeCloseTo(108, 0);
  });
});
