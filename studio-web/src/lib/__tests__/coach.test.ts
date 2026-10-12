import { describe, expect, it } from 'vitest';
import { consistency, consistencyScore } from '../coach';
import type { LapCornerStats } from '../coach';
import type { CornerStats } from '../corners';

const corner = (corner: number, brakeS: number, minSpeed = 80): CornerStats =>
  ({ corner, minSpeed, brakeS, valid: true } as unknown as CornerStats);

const lap = (key: string, time: number, brakes: number[]): LapCornerStats =>
  ({ key, label: key, time, stats: brakes.map((b, i) => corner(i + 1, b)) });

describe('consistency score', () => {
  it('is 100 for identical laps and falls with spread', () => {
    expect(consistencyScore(0, 0)).toBe(100);
    expect(consistencyScore(1, null)).toBe(50);
    expect(consistencyScore(2, 20)).toBe(0);
    expect(consistencyScore(1, 10)).toBe(50);
    expect(consistencyScore(null, 5)).toBeNull();
  });

  it('measures brake-point spread per corner and names the worst corner', () => {
    const c = consistency([
      lap('1', 90.0, [100, 500, 900]),
      lap('2', 90.4, [102, 530, 901]),
      lap('3', 90.2, [98, 470, 899]),
    ]);
    expect(c.brakeSd).toHaveLength(3);
    expect(c.worstBrakeCorner?.corner).toBe(2);
    expect(c.brakeSdMedian).toBeCloseTo(2, 5);
    expect(c.score).not.toBeNull();
    expect(c.score!).toBeGreaterThan(80);
  });

  it('skips corners without enough valid brake points', () => {
    const c = consistency([lap('1', 90, [NaN, 500]), lap('2', 91, [NaN, 505]), lap('3', 90.5, [100, 510])]);
    expect(c.brakeSd.map((b) => b.corner)).toEqual([2]);
  });
});
