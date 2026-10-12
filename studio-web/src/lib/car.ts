// Car-side analysis from the OBD columns: revs at the shift, time at full throttle, time with
// neither pedal, and engine temperatures. Turns them into plain guidance next to the corner tips.

import type { LapData } from './types';

/** Accelerator above this (%) counts as on the throttle. Matches the phone's track screen. */
export const THROTTLE_ON = 5;
/** Accelerator at or above this (%) counts as flat out. */
export const FULL_THROTTLE = 90;
export const TEMP_LIMITS = { coolant: 105, oil: 130, intake: 55 } as const;

export interface CarLapStats {
  key: string;
  label: string;
  time: number;
  maxRpm: number | null;
  /** Typical revs at an upshift (median of detected shifts). */
  shiftRpm: number | null;
  shifts: number;
  /** Share of the lap, by time, flat out. */
  fullThrottlePct: number | null;
  /** Seconds with the foot off the accelerator and not braking. */
  coastSeconds: number | null;
  coolantMax: number | null;
  oilMax: number | null;
  intakeMax: number | null;
}

const fin = (v: number | null | undefined): v is number => v != null && Number.isFinite(v);

function maxOf(a: Float32Array | null | undefined): number | null {
  if (!a) return null;
  let m = -Infinity;
  for (const v of a) if (Number.isFinite(v) && v > m) m = v;
  return m === -Infinity ? null : m;
}

function median(xs: number[]): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const k = s.length >> 1;
  return s.length % 2 ? s[k] : (s[k - 1] + s[k]) / 2;
}

/** The accelerator pedal when the car reports it, otherwise the throttle plate. */
export function pedalOf(lap: LapData): Float32Array | null {
  return lap.car?.pedal ?? lap.car?.throttle ?? null;
}

/**
 * Upshifts: a revs peak followed within a second by a drop of more than 1000 rpm while the car
 * keeps its speed. Braking downchanges lose speed, so they don't count.
 */
export function detectShifts(lap: LapData): number[] {
  const rpm = lap.car?.rpm;
  if (!rpm) return [];
  const out: number[] = [];
  const n = rpm.length;
  let i = 1;
  while (i < n - 1) {
    const r = rpm[i];
    if (!fin(r) || r < 2500 || !(r >= (rpm[i - 1] ?? -1) || !fin(rpm[i - 1]))) { i++; continue; }
    let shifted = -1;
    for (let j = i + 1; j < n && lap.t[j] - lap.t[i] <= 1; j++) {
      if (!fin(rpm[j])) continue;
      if (rpm[j] > r) break;                      // still climbing: not the peak
      if (r - rpm[j] > 1000 && lap.speed[j] >= lap.speed[i] - 3) { shifted = j; break; }
    }
    if (shifted > 0) { out.push(r); i = shifted + 1; } else i++;
  }
  return out;
}

export function carLapStats(lap: LapData, label: string): CarLapStats | null {
  const car = lap.car;
  if (!car) return null;
  const pedal = pedalOf(lap);
  let full = 0, coast = 0, known = 0;
  if (pedal) {
    for (let i = 1; i < lap.t.length; i++) {
      const dt = lap.t[i] - lap.t[i - 1];
      const p = pedal[i];
      if (!(dt > 0 && dt < 2) || !fin(p)) continue;
      known += dt;
      if (p >= FULL_THROTTLE) full += dt;
      else if (p <= THROTTLE_ON) {
        // Off the pedal: braking if the car slows hard, else coasting.
        const g = lap.gLong && fin(lap.gLong[i]) ? lap.gLong[i] : (lap.speed[i] - lap.speed[i - 1]) / 3.6 / dt / 9.80665;
        if (g > -0.15) coast += dt;
      }
    }
  }
  const shifts = detectShifts(lap);
  return {
    key: lap.key, label, time: lap.time,
    maxRpm: maxOf(car.rpm),
    shiftRpm: median(shifts),
    shifts: shifts.length,
    fullThrottlePct: known > lap.time * 0.5 ? (full / known) * 100 : null,
    coastSeconds: known > lap.time * 0.5 ? coast * (lap.time / known) : null,
    coolantMax: maxOf(car.coolant),
    oilMax: maxOf(car.oil),
    intakeMax: maxOf(car.intake),
  };
}

export interface CarAdvice {
  topic: 'shift' | 'throttle' | 'coast' | 'temps';
  text: string;
  level: 'tip' | 'warn';
}

export interface CarSummary {
  ref: CarLapStats;
  laps: CarLapStats[];
  sessionMaxRpm: number | null;
  advice: CarAdvice[];
}

const r0 = (v: number) => Math.round(v);
const roundTo = (v: number, step: number) => Math.round(v / step) * step;

/** Compare the timed laps with the reference lap and say what the car data shows. */
export function carSummary(ref: CarLapStats | null, laps: CarLapStats[]): CarSummary | null {
  if (!ref) return null;
  const others = laps.filter((l) => l.key !== ref.key);
  const advice: CarAdvice[] = [];
  const sessionMaxRpm = laps.concat(ref).reduce<number | null>((m, l) => (l.maxRpm != null && (m == null || l.maxRpm > m) ? l.maxRpm : m), null);

  // Shifts: short-shifting leaves power unused; living on the limiter wastes time too.
  const shift = ref.shiftRpm ?? median(laps.map((l) => l.shiftRpm).filter(fin));
  if (shift != null && sessionMaxRpm != null) {
    if (sessionMaxRpm - shift > 700) {
      advice.push({ topic: 'shift', level: 'tip', text: `You usually change up at about ${roundTo(shift, 100)} rpm but the engine reached ${roundTo(sessionMaxRpm, 100)} rpm this session. On the straights, hold each gear a little longer before changing up.` });
    } else {
      advice.push({ topic: 'shift', level: 'tip', text: `Your upshifts sit around ${roundTo(shift, 100)} rpm, close to the highest revs you used. Keep them there.` });
    }
  }

  // Full throttle: the reference lap against the typical lap.
  const typFull = median(others.map((l) => l.fullThrottlePct).filter(fin));
  if (ref.fullThrottlePct != null && typFull != null && ref.fullThrottlePct - typFull >= 3) {
    advice.push({ topic: 'throttle', level: 'tip', text: `Your best lap was flat out ${r0(ref.fullThrottlePct)}% of the time, against ${r0(typFull)}% on a typical lap. Commit to full throttle sooner on corner exits.` });
  } else if (ref.fullThrottlePct != null) {
    advice.push({ topic: 'throttle', level: 'tip', text: `Flat out for ${r0(ref.fullThrottlePct)}% of your best lap.` });
  }

  // Coasting: time with neither pedal is time not gaining.
  const typCoast = median(others.map((l) => l.coastSeconds).filter(fin));
  const coast = typCoast ?? ref.coastSeconds;
  if (coast != null && coast >= 1.5) {
    advice.push({ topic: 'coast', level: 'tip', text: `About ${coast.toFixed(1)} s per lap with neither pedal pressed. Aim to go straight from the brake to a little throttle through the corner.` });
  }

  // Temperatures.
  const hot = (pick: (l: CarLapStats) => number | null) => laps.concat(ref).reduce<number | null>((m, l) => { const v = pick(l); return v != null && (m == null || v > m) ? v : m; }, null);
  const oil = hot((l) => l.oilMax), coolant = hot((l) => l.coolantMax), intake = hot((l) => l.intakeMax);
  if (oil != null && oil >= TEMP_LIMITS.oil) advice.push({ topic: 'temps', level: 'warn', text: `Oil reached ${r0(oil)} °C. Do a slow cool-down lap before it climbs further, and check the oil level after the session.` });
  if (coolant != null && coolant >= TEMP_LIMITS.coolant) advice.push({ topic: 'temps', level: 'warn', text: `Coolant reached ${r0(coolant)} °C. Back off for a lap and let it settle.` });
  if (intake != null && intake >= TEMP_LIMITS.intake) advice.push({ topic: 'temps', level: 'tip', text: `Intake air reached ${r0(intake)} °C. Hot intake air costs power, so expect slower straights later in a stint.` });
  if ((oil != null || coolant != null) && !advice.some((a) => a.topic === 'temps')) {
    const parts = [coolant != null ? `coolant ${r0(coolant)} °C` : null, oil != null ? `oil ${r0(oil)} °C` : null].filter(Boolean).join(', ');
    advice.push({ topic: 'temps', level: 'tip', text: `Temperatures stayed in range: ${parts} at most.` });
  }

  return { ref, laps, sessionMaxRpm, advice };
}

export interface StintRow { key: string; label: string; time: number; oil: number | null; coolant: number | null }
export interface Stint {
  rows: StintRow[];
  /** Seconds of lap time per 10 °C of oil (or coolant when there is no oil), from a least-squares fit. */
  secPer10C: number | null;
  tempChannel: 'oil' | 'coolant' | null;
}

/** Lap time against the hottest oil and coolant of each lap, in the order the laps were driven. */
export function stint(laps: CarLapStats[]): Stint | null {
  const rows = laps.filter((l) => fin(l.time)).map((l) => ({ key: l.key, label: l.label, time: l.time, oil: l.oilMax, coolant: l.coolantMax }));
  if (rows.length < 2 || !rows.some((r) => r.oil != null || r.coolant != null)) return null;
  const fit = (pick: (r: StintRow) => number | null) => {
    const pts = rows.map((r) => [pick(r), r.time] as const).filter((p): p is readonly [number, number] => fin(p[0]));
    if (pts.length < 4) return null;
    const mx = pts.reduce((s, p) => s + p[0], 0) / pts.length, my = pts.reduce((s, p) => s + p[1], 0) / pts.length;
    const sxx = pts.reduce((s, p) => s + (p[0] - mx) ** 2, 0);
    if (Math.max(...pts.map((p) => p[0])) - Math.min(...pts.map((p) => p[0])) < 5 || sxx === 0) return null;
    return (pts.reduce((s, p) => s + (p[0] - mx) * (p[1] - my), 0) / sxx) * 10;
  };
  const oil = fit((r) => r.oil);
  if (oil != null) return { rows, secPer10C: oil, tempChannel: 'oil' };
  const coolant = fit((r) => r.coolant);
  return { rows, secPer10C: coolant, tempChannel: coolant != null ? 'coolant' : null };
}
