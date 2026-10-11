import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { parseCsv, matchHeader } from '../csv/parse';
import { analyzeSession } from '../analysis';
import { BUILTIN_TRACKS } from '../tracks';
import type { SessionRecord } from '../types';

const samplePath = fileURLToPath(new URL('../../../../shared/sample-phone-session.csv', import.meta.url));
const sample = readFileSync(samplePath, 'utf8');

function record(text: string): SessionRecord {
  const r = parseCsv(text, 'x.csv');
  if (!r.ok) throw new Error(r.error);
  const s = r.session;
  return {
    id: 'test', name: 'test', fileName: 'x.csv', importedAt: new Date().toISOString(),
    date: s.date, meta: s.meta, channels: s.channels, report: s.report, customGate: null,
  };
}

describe('parseCsv on the sample phone session', () => {
  it('parses metadata, columns and rows', () => {
    const r = parseCsv(sample, 'sample.csv');
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.session.meta['Date UTC']).toBe('2026-07-03T12:00:00Z');
    expect(r.session.report.rows).toBe(3421);
    expect(Math.round(r.session.report.sampleRateHz)).toBe(10);
    expect(r.session.report.delimiter).toBe('comma');
    expect(r.session.channels.gLong).not.toBeNull();
  });

  it('yields Out, 1, 2, 3, In with best lap 2 ≈ 61.9 s', () => {
    const a = analyzeSession(record(sample), BUILTIN_TRACKS);
    expect(a.lapSource).toBe('csv');
    expect(a.laps.map((l) => l.label)).toEqual(['Out', '1', '2', '3', 'In']);
    expect(a.laps.map((l) => l.kind)).toEqual(['out', 'timed', 'timed', 'timed', 'in']);
    expect(a.bestLapIndex).toBe(2);
    expect(a.laps[2].time).toBeCloseTo(61.9, 1);
    expect(a.lowRateGps).toBe(true);
  });
});

describe('parseCsv contract', () => {
  it('handles semicolons, decimal commas, units in brackets and mph', () => {
    const text = [
      '# comment',
      'Date UTC;2026-01-01T10:00:00Z',
      'Time;Lap;Lat;Lon;Speed [mph]',
      '0,0;1;42,1;23,1;10',
      '0,1;1;42,10001;23,1;10',
      '0,2;1;42,10002;23,1;10',
    ].join('\n');
    const r = parseCsv(text);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.session.report.delimiter).toBe('semicolon');
    expect(r.session.channels.lat[1]).toBeCloseTo(42.10001, 6);
    expect(r.session.channels.speed[0]).toBeCloseTo(16.09, 2);
    expect(r.session.date).toBe('2026-01-01T10:00:00.000Z');
  });

  it('detects unix milliseconds and clock times', () => {
    const ms = parseCsv('time,lat,lon\n1700000000000,42.1,23.1\n1700000000100,42.1001,23.1\n');
    expect(ms.ok && ms.session.channels.t[1] - ms.session.channels.t[0]).toBeCloseTo(0.1, 6);
    const clock = parseCsv('time,lat,lon\n12:00:00.0,42.1,23.1\n12:00:00.5,42.1001,23.1\n');
    expect(clock.ok && clock.session.channels.t[1]).toBeCloseTo(43200.5, 6);
  });

  it('reports missing required columns in plain language', () => {
    const r = parseCsv('Time,Latitude,Speed\n1,2,3\n');
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.error).toMatch(/Longitude/);
  });

  it('rejects duplicate headers', () => {
    const r = parseCsv('Time,Lat,Lon,Lon\n1,2,3,3\n');
    expect(r.ok).toBe(false);
  });

  it('maps aliases with and without units', () => {
    expect(matchHeader('Speed (km/h)')).toEqual({ field: 'speed', unit: 'kmh' });
    expect(matchHeader('Lateral (g)').field).toBe('gLat');
    expect(matchHeader('GForceX').field).toBe('gx');
    expect(matchHeader('SpeedKmh')).toEqual({ field: 'speed', unit: 'kmh' });
  });

  it('flags generic G axes as unconfirmed and derives speed', () => {
    const r = parseCsv('time,lat,lon,GForceX,GForceY\n0,42,23,0.1,0.2\n1,42.0001,23,0.1,0.2\n2,42.0002,23,0.1,0.2\n');
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.session.report.gAxesConfirmed).toBe(false);
    expect(r.session.report.speedDerived).toBe(true);
    expect(r.session.channels.speed[1]).toBeGreaterThan(30); // ~11 m/s = 40 km/h
  });
});
