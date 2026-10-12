import { describe, expect, it } from 'vitest';
import { parseCsv } from '../csv/parse';
import { carLapStats, carSummary, detectShifts } from '../car';
import { DRIVE_ACCEL, DRIVE_BRAKE, DRIVE_COAST, driveStates } from '../insights';
import { verifyNumbers } from '../aicoach';
import type { CarChannels, LapData } from '../types';

/** A straight-line lap sampled at 10 Hz. */
function lap(speedKmh: number[], car: CarChannels, key = 'a'): LapData {
  const n = speedKmh.length;
  return {
    key, label: key, time: (n - 1) / 10,
    t: Float64Array.from({ length: n }, (_, i) => i / 10),
    speed: Float32Array.from(speedKmh),
    gLong: null, gLat: null, car,
  } as unknown as LapData;
}

describe('OBD columns in the CSV', () => {
  it('reads the car channels and keeps GPS speed separate from OBD speed', () => {
    const text = [
      'Time (s),Latitude,Longitude,Speed (km/h),Engine RPM,Accelerator Pedal (%),Coolant Temp (°C),Oil Temp (°C),OBD Speed (km/h)',
      '0.0,42.1,23.1,100,5200,95,92,,101',
      '0.1,42.10001,23.1,101,,,,,',
      '0.2,42.10002,23.1,102,5400,96,,104,103',
    ].join('\n');
    const r = parseCsv(text);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const c = r.session.channels;
    expect(c.speed[0]).toBe(100);
    expect(c.obdSpeed?.[0]).toBe(101);
    expect(c.rpm?.[2]).toBe(5400);
    expect(Number.isNaN(c.rpm?.[1])).toBe(true);
    expect(c.pedal?.[0]).toBe(95);
    expect(c.coolant?.[0]).toBe(92);
    expect(c.oil?.[2]).toBe(104);
  });
});

describe('driveStates with the accelerator recorded', () => {
  it('uses the pedal to split throttle from coasting, and g for braking', () => {
    const speed = [...Array(20).fill(100), 95, 90, 85, 80, 75, 70, 65, 60];
    const pedal = Float32Array.from(speed.map((_, i) => (i >= 5 && i < 12 ? 50 : 0)));
    const s = driveStates(lap(speed, { pedal }));
    expect(s[2]).toBe(DRIVE_COAST);
    expect(s[8]).toBe(DRIVE_ACCEL);
    expect(s[24]).toBe(DRIVE_BRAKE);
  });
});

describe('car analysis', () => {
  // Revs climb to 6000, drop to 4200 at the shift while speed holds, then a braking downshift.
  const rpm: number[] = [], speed: number[] = [], pedal: number[] = [];
  for (let i = 0; i < 40; i++) { rpm.push(3000 + i * 75); speed.push(80 + i); pedal.push(100); }
  for (let i = 0; i < 20; i++) { rpm.push(4200 + i * 40); speed.push(120 + i * 0.5); pedal.push(100); }
  for (let i = 0; i < 20; i++) { rpm.push(5000 - i * 50); speed.push(130 - i * 4); pedal.push(0); }
  const fast = lap(speed, { rpm: Float32Array.from(rpm), pedal: Float32Array.from(pedal), oil: Float32Array.from(rpm.map(() => 133)), coolant: Float32Array.from(rpm.map(() => 95)) });

  it('finds upshifts but not braking downshifts', () => {
    expect(detectShifts(fast)).toHaveLength(1);
    expect(detectShifts(fast)[0]).toBeCloseTo(5925, 0);
  });

  it('measures full throttle and warns about hot oil first', () => {
    const st = carLapStats(fast, '7')!;
    expect(st.fullThrottlePct).toBeGreaterThan(70);
    expect(st.oilMax).toBe(133);
    const sum = carSummary(st, [st])!;
    expect(sum.advice.find((a) => a.topic === 'temps')).toMatchObject({ level: 'warn' });
    expect(sum.advice.some((a) => a.level === 'warn' && /Coolant/.test(a.text))).toBe(false);
  });

  it('suggests later upshifts when the engine revved higher elsewhere', () => {
    const st = carLapStats(fast, '7')!;
    const sum = carSummary({ ...st, shiftRpm: 5000 }, [{ ...st, key: 'b', maxRpm: 6400 }])!;
    expect(sum.advice.find((a) => a.topic === 'shift')!.text).toMatch(/5000 rpm.*6400 rpm/);
  });

  it('returns nothing without car data', () => {
    expect(carLapStats(lap([1, 2, 3], undefined as unknown as CarChannels), 'x')).toBeNull();
  });

  it('advice texts only use numbers the facts contain', () => {
    const st = carLapStats(fast, '7')!;
    const sum = carSummary(st, [st])!;
    const facts = { car: { observations: sum.advice.map((a) => a.text) } };
    expect(verifyNumbers(sum.advice.map((a) => a.text).join(' '), facts).ok).toBe(true);
  });
});
