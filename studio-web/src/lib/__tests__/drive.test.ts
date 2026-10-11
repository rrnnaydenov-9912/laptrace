import { describe, expect, it } from 'vitest';
import { driveStats, isDrive } from '../drive';
import type { Channels } from '../types';

// Straight line north at 0.0001° lat per second (~11.1 m/s = 40 km/h), with a 10 s stop in the middle.
function channels(): Channels {
  const n = 41;
  const t = new Float64Array(n), lat = new Float64Array(n), lon = new Float64Array(n), speed = new Float32Array(n);
  const gLong = new Float32Array(n), gLat = new Float32Array(n);
  let y = 42;
  for (let i = 0; i < n; i++) {
    const stopped = i > 15 && i <= 25;
    if (i > 0 && !stopped) y += 0.0001;
    t[i] = i; lat[i] = y; lon[i] = 23; speed[i] = stopped ? 0 : 40;
  }
  gLong[5] = -0.8; gLong[30] = 0.4; gLat[10] = -0.6;
  return { t, lat, lon, speed, alt: null, heading: null, gLong, gLat, gVert: null, accuracy: null, fix: null, lap: null };
}

describe('isDrive', () => {
  const noTrack = { track: null, lapSource: 'single' } as const;
  it('trusts the Mode key', () => {
    expect(isDrive({ meta: { Mode: 'Drive' } }, { track: {} as never, lapSource: 'gate' as never })).toBe(true);
    expect(isDrive({ meta: { Mode: 'track' } }, noTrack as never)).toBe(false);
  });
  it('treats a lapless recording off any known track as a drive', () => {
    expect(isDrive({ meta: {} }, noTrack as never)).toBe(true);
  });
});

describe('driveStats', () => {
  const st = driveStats(channels());
  it('measures distance and time', () => {
    expect(st.duration).toBe(40);
    expect(st.distance).toBeGreaterThan(330);
    expect(st.distance).toBeLessThan(340);
  });
  it('leaves stops out of moving time and average speed', () => {
    expect(st.movingTime).toBe(30);
    expect(st.avgMovingSpeed).toBeGreaterThan(38);
    expect(st.avgMovingSpeed).toBeLessThan(42);
  });
  it('reports peak g per direction', () => {
    expect(st.maxBrakeG).toBeCloseTo(0.8, 5);
    expect(st.maxAccelG).toBeCloseTo(0.4, 5);
    expect(st.maxLatG).toBeCloseTo(0.6, 5);
    expect(st.maxSpeed).toBe(40);
  });
});
