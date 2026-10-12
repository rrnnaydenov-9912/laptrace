import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { parseCsv } from '../csv/parse';
import { analyzeSession } from '../analysis';
import { BUILTIN_TRACKS } from '../tracks';
import { carLapStats, carSummary } from '../car';

// The "Try the sample" session in Studio: A1 Motor Park with every phone and car column.
const path = fileURLToPath(new URL('../../../public/sample-phone-session.csv', import.meta.url));
const text = readFileSync(path, 'utf8');

describe('Studio sample session (A1 Motor Park)', () => {
  const r = parseCsv(text, 'sample-phone-session.csv');
  if (!r.ok) throw new Error(r.error);
  const s = r.session;
  const a = analyzeSession({
    id: 's', name: 's', fileName: 'sample-phone-session.csv', importedAt: new Date().toISOString(),
    date: s.date, meta: s.meta, channels: s.channels, report: s.report, customGate: null,
  }, BUILTIN_TRACKS);

  it('is recognised as A1 Motor Park with five timed laps', () => {
    expect(a.track?.id).toBe('a1-motor-park-full');
    expect(a.laps.filter((l) => l.kind === 'timed')).toHaveLength(5);
    expect(a.bestLapIndex).not.toBeNull();
    expect(a.laps[a.bestLapIndex!].label).toBe('3');
  });

  it('carries every car channel', () => {
    const car = s.channels;
    for (const k of ['rpm', 'throttle', 'pedal', 'load', 'obdSpeed', 'coolant', 'oil', 'intake'] as const) {
      expect(car[k], k).toBeTruthy();
    }
  });

  it('gives shift, throttle and temperature guidance', () => {
    const timed = a.laps.filter((l) => l.kind === 'timed');
    const stats = timed.map((l) => carLapStats(l, l.label)!);
    const ref = stats[timed.indexOf(a.laps[a.bestLapIndex!])];
    expect(ref.shifts).toBeGreaterThan(3);
    const sum = carSummary(ref, stats)!;
    expect(sum.advice.map((x) => x.topic)).toEqual(expect.arrayContaining(['shift', 'throttle', 'temps']));
  });
});
