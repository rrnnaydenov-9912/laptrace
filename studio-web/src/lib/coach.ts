// Rule-based coach: quantified, plain-language opportunities. No AI, no network.

import { stdDev } from './geo';
import { fmtSpeedU } from './format';
import type { CornerStats } from './corners';

export interface CoachTip {
  corner: number;
  loss: number;
  text: string;
}

export interface LapCornerStats {
  key: string;
  label: string;
  time: number;
  stats: CornerStats[];
}

const fmtM = (v: number) => `${Math.round(Math.abs(v))} m`;
const fmtK = (v: number) => fmtSpeedU(Math.abs(v));

/** Describe how `lap` differs from `ref` in one corner zone. */
function describe(lap: CornerStats, ref: CornerStats): { title: string; phrases: string[] } {
  const phrases: string[] = [];
  let exitOnly = true;
  if (Number.isFinite(lap.brakeS) && Number.isFinite(ref.brakeS)) {
    const d = lap.brakeS - ref.brakeS;
    if (d <= -5) { phrases.push(`braking ${fmtM(d)} earlier`); exitOnly = false; }
    else if (d >= 5) { phrases.push(`braking ${fmtM(d)} later`); exitOnly = false; }
  }
  const dMin = lap.minSpeed - ref.minSpeed;
  if (dMin <= -2) { phrases.push(`min speed ${fmtK(dMin)} lower`); exitOnly = false; }
  else if (dMin >= 2) { phrases.push(`min speed ${fmtK(dMin)} higher but a slower exit`); exitOnly = false; }
  if (Number.isFinite(lap.throttleS) && Number.isFinite(ref.throttleS)) {
    const d = lap.throttleS - ref.throttleS;
    if (d >= 5) phrases.push(`throttle ${fmtM(d)} later`);
  }
  const dExit = lap.exitSpeed - ref.exitSpeed;
  if (dExit <= -2) phrases.push(`exit speed ${fmtK(dExit)} lower`);
  const title = exitOnly && phrases.length > 0 ? `Exit of corner ${lap.corner}` : `Corner ${lap.corner}`;
  return { title, phrases };
}

/** Top opportunities for `lap` against `ref`, biggest time loss first. */
export function coachLap(lap: LapCornerStats, ref: LapCornerStats, max = 3): CoachTip[] {
  const tips: CoachTip[] = [];
  for (let i = 0; i < lap.stats.length; i++) {
    const a = lap.stats[i];
    const b = ref.stats[i];
    if (!a?.valid || !b?.valid || a.lossVsRef <= 0.05) continue;
    const { title, phrases } = describe(a, b);
    const body = phrases.length ? phrases.join(', ') : 'slower through the zone with similar speeds (line or a lift?)';
    tips.push({ corner: a.corner, loss: a.lossVsRef, text: `${title}: ${body} — ~${a.lossVsRef.toFixed(2)} s lost` });
  }
  return tips.sort((x, y) => y.loss - x.loss).slice(0, max);
}

/** For the reference lap itself: where other laps were faster. */
export function coachReference(ref: LapCornerStats, others: LapCornerStats[], max = 3): CoachTip[] {
  const tips: CoachTip[] = [];
  for (let i = 0; i < ref.stats.length; i++) {
    const r = ref.stats[i];
    if (!r?.valid) continue;
    let best: { lap: LapCornerStats; st: CornerStats } | null = null;
    for (const o of others) {
      const st = o.stats[i];
      if (!st?.valid) continue;
      if (!best || st.zoneTime < best.st.zoneTime) best = { lap: o, st };
    }
    if (!best) continue;
    const gain = r.zoneTime - best.st.zoneTime;
    if (gain <= 0.05) continue;
    const { phrases } = describe(r, best.st);
    const how = phrases.length ? ` (here you were ${phrases.join(', ')})` : '';
    tips.push({
      corner: r.corner,
      loss: gain,
      text: `Corner ${r.corner}: lap ${best.lap.label} was ${gain.toFixed(2)} s quicker${how}`,
    });
  }
  return tips.sort((x, y) => y.loss - x.loss).slice(0, max);
}

export interface Consistency {
  lapTimeSd: number | null;
  lapCount: number;
  worstCorner: { corner: number; sd: number } | null;
  perCornerSd: { corner: number; sd: number }[];
}

export function consistency(laps: LapCornerStats[]): Consistency {
  const times = laps.map((l) => l.time);
  const nCorners = laps[0]?.stats.length ?? 0;
  const perCornerSd: { corner: number; sd: number }[] = [];
  for (let i = 0; i < nCorners; i++) {
    const v = laps.map((l) => l.stats[i]).filter((s) => s?.valid && Number.isFinite(s.minSpeed)).map((s) => s.minSpeed);
    if (v.length >= 2) perCornerSd.push({ corner: i + 1, sd: stdDev(v) });
  }
  const worst = perCornerSd.reduce<{ corner: number; sd: number } | null>((a, b) => (!a || b.sd > a.sd ? b : a), null);
  return {
    lapTimeSd: times.length >= 2 ? stdDev(times) : null,
    lapCount: times.length,
    worstCorner: worst,
    perCornerSd,
  };
}
