import { describe, expect, it } from 'vitest';
import type { CornerStats, Corner } from '../corners';
import type { LapCornerStats } from '../coach';
import { setSpeedUnit } from '../format';
import {
  DRIVE_ACCEL, DRIVE_BRAKE, DRIVE_COAST, bestConsecutive, classifyCause, driveStates,
  evaluateGoal, goalCopy, opportunities, outlierKeys, suggestGoal, targetTime,
} from '../insights';
import type { LapData } from '../types';
import type { Workspace } from '../workspace';

function st(corner: number, p: Partial<CornerStats> = {}): CornerStats {
  return {
    corner, entrySpeed: 120, minSpeed: 70, minS: 500, exitSpeed: 110, timeInCorner: 4,
    zoneTime: 6, brakeS: 400, throttleS: 520, lossVsRef: 0, valid: true, ...p,
  } as CornerStats;
}
const lap = (key: string, time: number, stats: CornerStats[]): LapCornerStats => ({ key, label: key, time, stats });

const corner = (number: number, sApex: number, apexLat: number): Corner => ({
  number, direction: 'R', sStart: sApex - 40, sEnd: sApex + 40, sApex, angle: 90,
  apexLat, apexLon: 23, zoneStart: sApex - 150, zoneEnd: sApex + 100,
});

describe('classifyCause', () => {
  it('picks braking when the faster lap braked clearly later', () => {
    expect(classifyCause(st(1, { brakeS: 400 }), st(1, { brakeS: 420, minSpeed: 71 })).cause).toBe('braking');
  });
  it('picks min speed when that is the biggest difference', () => {
    const c = classifyCause(st(1), st(1, { minSpeed: 78, brakeS: 405 }));
    expect(c.cause).toBe('minSpeed');
    expect(c.slowValue).toBe(70);
    expect(c.fastValue).toBe(78);
  });
  it('says unclear when speeds are the same', () => {
    expect(classifyCause(st(1), st(1)).cause).toBe('unclear');
  });
});

describe('opportunities and target', () => {
  const ref = lap('3', 90, [st(1), st(2), st(3)]);
  const others = [
    lap('2', 91, [st(1, { zoneTime: 5.6, brakeS: 425 }), st(2, { zoneTime: 6.02 }), st(3, { zoneTime: 6.3 })]),
    lap('4', 91.5, [st(1, { zoneTime: 5.8 }), st(2, { zoneTime: 5.7, minSpeed: 76 }), st(3)]),
  ];
  const opps = opportunities(ref, [ref, ...others]);
  it('ranks by gain and ignores tiny ones', () => {
    expect(opps.map((o) => o.corner)).toEqual([1, 2]);
    expect(opps[0].gain).toBeCloseTo(0.4, 6);
    expect(opps[0].fromLabel).toBe('2');
    expect(opps[0].cause).toBe('braking');
    expect(opps[1].cause).toBe('minSpeed');
  });
  it('builds a target from the top gains', () => {
    const t = targetTime(90, opps);
    expect(t.time).toBeCloseTo(89.3, 6);
    expect(t.corners).toEqual([1, 2]);
  });
});

describe('lap selection helpers', () => {
  it('flags a traffic lap as an outlier', () => {
    const laps = [60.1, 60.4, 59.9, 60.2, 66.0].map((time, i) => ({ key: `${i}`, time }));
    expect([...outlierKeys(laps)]).toEqual(['4']);
  });
  it('needs four laps before flagging anything', () => {
    expect(outlierKeys([{ key: 'a', time: 60 }, { key: 'b', time: 70 }, { key: 'c', time: 61 }]).size).toBe(0);
  });
  it('finds the best three consecutive laps', () => {
    const laps = [62, 61, 60, 60.5, 63].map((time, i) => ({ key: `${i}`, label: `${i + 1}`, time }));
    const b = bestConsecutive(laps)!;
    expect(b.from).toBe('2');
    expect(b.to).toBe('4');
    expect(b.avg).toBeCloseTo(60.5, 6);
  });
});

describe('drive states', () => {
  it('classifies from speed change when there is no g data', () => {
    const n = 60;
    const t = Float64Array.from({ length: n }, (_, i) => i / 10);
    // 0–2 s accelerate 5 m/s², 2–4 s constant, 4–6 s brake 8 m/s².
    const v = Array.from(t, (x) => (x < 2 ? 20 + 5 * x : x < 4 ? 30 : 30 - 8 * (x - 4)));
    const l = { t, speed: Float32Array.from(v.map((x) => x * 3.6)), gLong: null } as unknown as LapData;
    const s = driveStates(l);
    expect(s[10]).toBe(DRIVE_ACCEL);
    expect(s[30]).toBe(DRIVE_COAST);
    expect(s[50]).toBe(DRIVE_BRAKE);
  });
});

describe('goals', () => {
  const ws = { corners: [corner(1, 500, 42.0), corner(2, 1200, 42.01)] } as unknown as Workspace;
  const ref = lap('3', 90, [st(1), st(2)]);
  const fast = lap('2', 91, [st(1, { zoneTime: 5.5, brakeS: 425 }), st(2)]);

  it('asks for consistency first when laps are scattered', () => {
    const g = suggestGoal({ ws, opps: opportunities(ref, [ref, fast]), lapTimeSd: 2.0, lapCount: 5, trackId: 't', trackName: 'T', sessionId: 's' })!;
    expect(g.skill).toBe('consistency');
    expect(g.target).toBe(1.4);
  });

  it('turns a braking gain into a measurable goal and tracks it', () => {
    const g = suggestGoal({ ws, opps: opportunities(ref, [ref, fast]), lapTimeSd: 0.4, lapCount: 5, trackId: 't', trackName: 'T', sessionId: 's' })!;
    expect(g.skill).toBe('braking');
    expect(g.baseline).toBe(100); // 500 − 400
    expect(g.target).toBe(75); // 500 − 425
    expect(goalCopy(g).title).toBe('Corner 1: brake 25 m later');

    // Next session: corners renumbered (an extra corner first), same apex position.
    const ws2 = { corners: [corner(1, 200, 41.99), corner(2, 520, 42.0)] } as unknown as Workspace;
    const laps = [80, 78, 70, 74].map((b, i) => lap(`${i}`, 90, [st(1), st(2, { brakeS: 520 - b })]));
    const p = evaluateGoal(g, ws2, laps, 0.4);
    expect(p.laps).toBe(4);
    expect(p.best).toBe(70);
    expect(p.hits).toBe(2);
    expect(p.median).toBe(76);
    expect(p.achieved).toBe(false);
  });

  it('writes speed goals in the chosen unit', () => {
    const g = suggestGoal({
      ws, opps: opportunities(ref, [ref, lap('2', 91, [st(1, { zoneTime: 5.5, minSpeed: 80 }), st(2)])]),
      lapTimeSd: 0.4, lapCount: 5, trackId: 't', trackName: 'T', sessionId: 's',
    })!;
    expect(g.skill).toBe('minSpeed');
    setSpeedUnit('mph');
    expect(goalCopy(g).title).toBe('Corner 1: carry 6 mph more at the slowest point');
    setSpeedUnit('kmh');
    expect(goalCopy(g).title).toBe('Corner 1: carry 10 km/h more at the slowest point');
  });
});
