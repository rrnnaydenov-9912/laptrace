// Session-level insights for drivers new to track work: where the time is,
// a realistic target, consistency with outliers set aside, and one measurable
// goal for the next session. Pure functions; every number here is computed
// from the data, never invented.

import { median } from './geo';
import type { CornerStats } from './corners';
import type { LapCornerStats } from './coach';
import type { LapData } from './types';
import type { Workspace } from './workspace';
import { fmtSpeedU } from './format';

export type Cause = 'braking' | 'minSpeed' | 'throttle' | 'exit' | 'unclear';

export interface Opportunity {
  corner: number;
  /** Seconds the reference lap could gain in this corner zone. */
  gain: number;
  /** Lap that was quickest through this corner. */
  fromKey: string;
  fromLabel: string;
  cause: Cause;
  /** Reference figure and the faster lap's figure for the cause, in display units of the cause. */
  refValue: number | null;
  bestValue: number | null;
}

const CAUSE_TEXT: Record<Cause, string> = {
  braking: 'braking point',
  minSpeed: 'minimum corner speed',
  throttle: 'throttle pick-up',
  exit: 'exit speed',
  unclear: 'time through the corner',
};
export const causeLabel = (c: Cause) => CAUSE_TEXT[c];

/**
 * Main reason `slow` lost time to `fast` in one corner. Differences are scaled so
 * 10 m of brake/throttle point weighs the same as 2 km/h of speed.
 */
export function classifyCause(slow: CornerStats, fast: CornerStats): { cause: Cause; slowValue: number | null; fastValue: number | null } {
  const cands: { cause: Cause; score: number; slowValue: number; fastValue: number }[] = [];
  if (Number.isFinite(slow.brakeS) && Number.isFinite(fast.brakeS)) {
    // Braking earlier than the faster lap = brake point at a smaller distance.
    const d = fast.brakeS - slow.brakeS;
    if (d >= 5) cands.push({ cause: 'braking', score: d / 10, slowValue: slow.brakeS, fastValue: fast.brakeS });
  }
  const dMin = fast.minSpeed - slow.minSpeed;
  if (dMin >= 2) cands.push({ cause: 'minSpeed', score: dMin / 2, slowValue: slow.minSpeed, fastValue: fast.minSpeed });
  if (Number.isFinite(slow.throttleS) && Number.isFinite(fast.throttleS)) {
    const d = slow.throttleS - fast.throttleS;
    if (d >= 5) cands.push({ cause: 'throttle', score: d / 10, slowValue: slow.throttleS, fastValue: fast.throttleS });
  }
  const dExit = fast.exitSpeed - slow.exitSpeed;
  if (dExit >= 2) cands.push({ cause: 'exit', score: (dExit / 2) * 0.8, slowValue: slow.exitSpeed, fastValue: fast.exitSpeed });
  if (!cands.length) return { cause: 'unclear', slowValue: null, fastValue: null };
  cands.sort((a, b) => b.score - a.score);
  return { cause: cands[0].cause, slowValue: cands[0].slowValue, fastValue: cands[0].fastValue };
}

/**
 * Per corner: how much the reference lap could gain by matching the quickest
 * lap through that corner. Biggest first; gains under `minGain` are dropped.
 */
export function opportunities(ref: LapCornerStats, laps: LapCornerStats[], minGain = 0.05): Opportunity[] {
  const out: Opportunity[] = [];
  for (let i = 0; i < ref.stats.length; i++) {
    const r = ref.stats[i];
    if (!r?.valid) continue;
    let best: { lap: LapCornerStats; st: CornerStats } | null = null;
    for (const l of laps) {
      if (l.key === ref.key) continue;
      const st = l.stats[i];
      if (!st?.valid) continue;
      if (!best || st.zoneTime < best.st.zoneTime) best = { lap: l, st };
    }
    if (!best) continue;
    const gain = r.zoneTime - best.st.zoneTime;
    if (!(gain >= minGain)) continue;
    const c = classifyCause(r, best.st);
    out.push({
      corner: r.corner, gain, fromKey: best.lap.key, fromLabel: best.lap.label,
      cause: c.cause, refValue: c.slowValue, bestValue: c.fastValue,
    });
  }
  return out.sort((a, b) => b.gain - a.gain);
}

/** A realistic next target: the reference lap plus the top `n` corner gains. */
export function targetTime(refTime: number, opps: Opportunity[], n = 3): { time: number; gain: number; corners: number[] } {
  const top = opps.slice(0, n);
  const gain = top.reduce((a, o) => a + o.gain, 0);
  return { time: refTime - gain, gain, corners: top.map((o) => o.corner) };
}

export function quantile(sorted: number[], q: number): number {
  if (!sorted.length) return NaN;
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

/**
 * Laps that are unusually slow (traffic, a spin, a cool-down) by the
 * Tukey rule: slower than Q3 + 1.5 × IQR. Needs at least 4 laps.
 */
export function outlierKeys(laps: { key: string; time: number }[]): Set<string> {
  const out = new Set<string>();
  if (laps.length < 4) return out;
  const times = laps.map((l) => l.time).sort((a, b) => a - b);
  const q1 = quantile(times, 0.25);
  const q3 = quantile(times, 0.75);
  const limit = q3 + 1.5 * Math.max(q3 - q1, 0.2);
  for (const l of laps) if (l.time > limit) out.add(l.key);
  return out;
}

/** Fastest run of `n` consecutive laps (in driving order), as total and average. */
export function bestConsecutive(laps: { key: string; label: string; time: number }[], n = 3): { total: number; avg: number; from: string; to: string } | null {
  if (laps.length < n) return null;
  let best: { total: number; i: number } | null = null;
  for (let i = 0; i + n <= laps.length; i++) {
    let total = 0;
    for (let k = 0; k < n; k++) total += laps[i + k].time;
    if (!best || total < best.total) best = { total, i };
  }
  if (!best) return null;
  return { total: best.total, avg: best.total / n, from: laps[best.i].label, to: laps[best.i + n - 1].label };
}

// --- Brake / throttle map ---------------------------------------------------

export const DRIVE_COAST = 0;
export const DRIVE_BRAKE = 1;
export const DRIVE_ACCEL = 2;

/**
 * Classify each sample as braking, accelerating or coasting. Uses longitudinal
 * g when present, otherwise the speed change over about ±0.5 s.
 */
export function driveStates(lap: LapData, brakeG = -0.15, accelG = 0.08): Uint8Array {
  const n = lap.t.length;
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    let g = NaN;
    if (lap.gLong && Number.isFinite(lap.gLong[i])) g = lap.gLong[i];
    else {
      let a = i;
      let b = i;
      while (a > 0 && lap.t[i] - lap.t[a - 1] <= 0.5) a--;
      while (b < n - 1 && lap.t[b + 1] - lap.t[i] <= 0.5) b++;
      const dt = lap.t[b] - lap.t[a];
      if (dt > 0) g = ((lap.speed[b] - lap.speed[a]) / 3.6 / dt) / 9.80665;
    }
    out[i] = g <= brakeG ? DRIVE_BRAKE : g >= accelG ? DRIVE_ACCEL : DRIVE_COAST;
  }
  return out;
}

// --- Next-session goal ------------------------------------------------------

export type Skill = 'consistency' | 'braking' | 'minSpeed' | 'throttle';

export interface Goal {
  id: string;
  trackId: string;
  trackName: string;
  createdAt: string;
  fromSessionId: string;
  skill: Skill;
  /** Corner the goal is about (null for consistency). Matched by apex position next time. */
  corner: number | null;
  apexLat: number | null;
  apexLon: number | null;
  /**
   * Metric the goal is measured in:
   *  consistency → lap-time σ (s, lower is better)
   *  braking     → brake point, metres before the apex (lower is better = brake later)
   *  minSpeed    → minimum corner speed (km/h, higher is better)
   *  throttle    → throttle pick-up, metres after the apex (lower is better)
   */
  baseline: number;
  target: number;
  /** Lap that showed the target is reachable, and its gain in that corner (s). */
  fromLabel: string | null;
  gain: number | null;
}

const round1 = (v: number) => Math.round(v * 10) / 10;

/**
 * The single most useful thing to work on next, following the usual order for
 * new track drivers: consistency first, then braking, then corner speed, then
 * throttle. Returns null when there is not enough data.
 */
export function suggestGoal(args: {
  ws: Workspace;
  opps: Opportunity[];
  lapTimeSd: number | null;
  lapCount: number;
  trackId: string;
  trackName: string;
  sessionId: string;
}): Goal | null {
  const { ws, opps, lapTimeSd, lapCount, trackId, trackName, sessionId } = args;
  const base = {
    id: `${trackId}:${Date.now().toString(36)}`, trackId, trackName,
    createdAt: new Date().toISOString(), fromSessionId: sessionId,
  };
  if (lapTimeSd != null && lapCount >= 3 && lapTimeSd > 1.0) {
    return {
      ...base, skill: 'consistency', corner: null, apexLat: null, apexLon: null,
      baseline: round1(lapTimeSd), target: round1(Math.max(0.5, lapTimeSd * 0.7)),
      fromLabel: null, gain: null,
    };
  }
  const order: Skill[] = ['braking', 'minSpeed', 'throttle'];
  const candidate = opps
    .filter((o) => (order as string[]).includes(o.cause))
    .sort((a, b) => order.indexOf(a.cause as Skill) - order.indexOf(b.cause as Skill) || b.gain - a.gain)[0];
  if (!candidate || candidate.refValue == null || candidate.bestValue == null) return null;
  const c = ws.corners.find((x) => x.number === candidate.corner);
  if (!c) return null;
  const common = {
    ...base, corner: c.number, apexLat: c.apexLat, apexLon: c.apexLon,
    fromLabel: candidate.fromLabel, gain: candidate.gain,
  };
  if (candidate.cause === 'braking') {
    return { ...common, skill: 'braking', baseline: Math.round(c.sApex - candidate.refValue), target: Math.round(c.sApex - candidate.bestValue) };
  }
  if (candidate.cause === 'minSpeed') {
    return { ...common, skill: 'minSpeed', baseline: Math.round(candidate.refValue), target: Math.round(candidate.bestValue) };
  }
  return { ...common, skill: 'throttle', baseline: Math.round(candidate.refValue - c.sApex), target: Math.round(candidate.bestValue - c.sApex) };
}

/** Plain-language title, reason and how-to for a goal, in the current display units. */
export function goalCopy(g: Goal): { title: string; why: string; how: string } {
  const gainTxt = g.gain != null ? `${g.gain.toFixed(2)} s` : '';
  switch (g.skill) {
    case 'consistency':
      return {
        title: `Bring lap-time spread down to ±${g.target.toFixed(1)} s`,
        why: `Your lap times varied by ±${g.baseline.toFixed(1)} s. Repeatable laps come before fast laps: they show what works and keep you safe in traffic.`,
        how: 'Pick fixed reference points (a board, a kerb, a cone) for braking and turn-in in every corner and use the same ones every lap. Drive at about 8/10.',
      };
    case 'braking':
      return {
        title: `Corner ${g.corner}: brake ${g.baseline - g.target} m later`,
        why: `On your best lap you started braking ${g.baseline} m before the apex of corner ${g.corner}. On lap ${g.fromLabel} you braked ${g.target} m before it and were ${gainTxt} quicker through the corner.`,
        how: 'Find a marker near where you brake now and move your braking point a few metres past it each lap. Brake firmly at first, then ease off as you turn in.',
      };
    case 'minSpeed':
      return {
        title: `Corner ${g.corner}: carry ${fmtSpeedU(g.target - g.baseline)} more at the slowest point`,
        why: `Your best lap's slowest point in corner ${g.corner} was ${fmtSpeedU(g.baseline)}. Lap ${g.fromLabel} kept ${fmtSpeedU(g.target)} and was ${gainTxt} quicker through it.`,
        how: 'Release the brake a little earlier and more gently so the car rolls into the corner faster. Build up a little each lap.',
      };
    case 'throttle':
      return {
        title: `Corner ${g.corner}: back on the throttle ${g.baseline - g.target} m sooner`,
        why: `On your best lap the speed started rising ${g.baseline} m after the apex of corner ${g.corner}. On lap ${g.fromLabel} it rose ${g.target} m after the apex, ${gainTxt} quicker.`,
        how: 'Once the car is turned and settled, squeeze the throttle gently and earlier. Smooth beats sudden.',
      };
  }
}

/** Format a value in a goal's metric, in display units. */
export function fmtGoalValue(skill: Skill, v: number | null): string {
  if (v == null || !Number.isFinite(v)) return '—';
  if (skill === 'consistency') return `±${v.toFixed(1)} s`;
  if (skill === 'minSpeed') return fmtSpeedU(v);
  return `${Math.round(v)} m`;
}

export interface GoalProgress {
  /** Laps measured this session. */
  laps: number;
  /** Laps that met the target. */
  hits: number;
  /** Best value this session, in the goal's metric. */
  best: number | null;
  /** Median value this session, in the goal's metric. */
  median: number | null;
  /** True when the median met the target. */
  achieved: boolean;
  /** Short explanation when it couldn't be measured. */
  note: string | null;
}

function lowerIsBetter(skill: Skill): boolean {
  return skill !== 'minSpeed';
}

/** Measure a stored goal on a session's timed laps. */
export function evaluateGoal(goal: Goal, ws: Workspace, laps: LapCornerStats[], lapTimeSd: number | null): GoalProgress {
  const none = (note: string): GoalProgress => ({ laps: 0, hits: 0, best: null, median: null, achieved: false, note });
  if (goal.skill === 'consistency') {
    if (lapTimeSd == null || laps.length < 2) return none('Needs at least 2 timed laps.');
    const v = round1(lapTimeSd);
    return { laps: laps.length, hits: v <= goal.target ? 1 : 0, best: v, median: v, achieved: v <= goal.target, note: null };
  }
  if (goal.apexLat == null || goal.apexLon == null) return none('Goal has no corner position.');
  // Match the corner by apex position; numbering can change between sessions.
  let corner = null;
  let bestD = Infinity;
  for (const c of ws.corners) {
    const dy = (c.apexLat - goal.apexLat) * 111_320;
    const dx = (c.apexLon - goal.apexLon) * 111_320 * Math.cos((goal.apexLat * Math.PI) / 180);
    const d = Math.hypot(dx, dy);
    if (d < bestD) { bestD = d; corner = c; }
  }
  if (!corner || bestD > 60) return none('Could not find the same corner in this session.');
  const idx = ws.corners.indexOf(corner);
  const values: number[] = [];
  for (const l of laps) {
    const st = l.stats[idx];
    if (!st?.valid) continue;
    let v = NaN;
    if (goal.skill === 'braking') v = corner.sApex - st.brakeS;
    else if (goal.skill === 'minSpeed') v = st.minSpeed;
    else v = st.throttleS - corner.sApex;
    if (Number.isFinite(v)) values.push(Math.round(v));
  }
  if (!values.length) return none('No lap had a clear measurement in that corner.');
  const lo = lowerIsBetter(goal.skill);
  const met = (v: number) => (lo ? v <= goal.target : v >= goal.target);
  const med = Math.round(median(values));
  return {
    laps: values.length,
    hits: values.filter(met).length,
    best: lo ? Math.min(...values) : Math.max(...values),
    median: med,
    achieved: met(med),
    note: null,
  };
}

export function metricName(skill: Skill): string {
  return skill === 'consistency' ? 'lap-time spread (±)'
    : skill === 'braking' ? 'brake point before apex'
    : skill === 'minSpeed' ? 'minimum speed'
    : 'throttle point after apex';
}
