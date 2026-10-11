// Lap segmentation: from the CSV Lap column or from start/finish gate crossings.

import { median } from './geo';
import type { Crossing } from './gates';
import type { LapKind, LapRange } from './types';

function labelNumber(label: string): number | null {
  const s = label.trim();
  if (/^[-+]?\d+(\.0+)?$/.test(s)) return Number.parseInt(s, 10);
  const m = s.match(/^lap\s*#?\s*(\d+)$/i);
  return m ? Number.parseInt(m[1], 10) : null;
}

function textKind(label: string): LapKind | null {
  const s = label.trim().toLowerCase().replace(/[\s_-]/g, '');
  if (s === 'out' || s === 'outlap') return 'out';
  if (s === 'in' || s === 'inlap') return 'in';
  if (s === 'pit' || s === 'pits' || s === 'pitlane') return 'pit';
  return null;
}

/**
 * Laps from the per-row label column. A lap runs from its first row to the
 * first row of the next lap, so lap time = start of next lap − start of this lap.
 * Label 0 before the first numbered lap is the out lap, after the last is the in lap.
 */
export function lapsFromLabels(labels: string[]): LapRange[] {
  const n = labels.length;
  if (n === 0) return [];
  const segs: { label: string; start: number }[] = [];
  for (let i = 0; i < n; i++) {
    const l = labels[i] === '' ? '0' : labels[i];
    if (segs.length === 0 || segs[segs.length - 1].label !== l) segs.push({ label: l, start: i });
  }
  const nums = segs.map((s) => labelNumber(s.label));
  const firstNumbered = nums.findIndex((v) => v != null && v > 0);
  let lastNumbered = -1;
  nums.forEach((v, i) => { if (v != null && v > 0) lastNumbered = i; });

  return segs.map((seg, i) => {
    const pStart = seg.start;
    const pEnd = i + 1 < segs.length ? segs[i + 1].start : n - 1;
    const num = nums[i];
    let kind: LapKind;
    let label = seg.label;
    const tk = textKind(seg.label);
    if (tk) {
      kind = tk;
      label = tk === 'out' ? 'Out' : tk === 'in' ? 'In' : 'Pit';
    } else if (num != null && num > 0) {
      kind = 'timed';
      label = String(num);
    } else if (num === 0 || num == null && seg.label.trim() === '0') {
      if (firstNumbered < 0) { kind = 'run'; label = 'Run'; }
      else if (i < firstNumbered) { kind = 'out'; label = 'Out'; }
      else if (i > lastNumbered) { kind = 'in'; label = 'In'; }
      else { kind = 'pit'; label = 'Pit'; }
    } else {
      kind = 'timed';
    }
    // The last segment's end is the last sample; a trailing "timed" lap without
    // a following lap start is incomplete.
    if (kind === 'timed' && i === segs.length - 1) kind = 'in';
    return { label, kind, number: kind === 'timed' ? num : null, pStart, pEnd };
  });
}

/** Laps from start/finish crossings: Out, timed laps between crossings, In. */
export function lapsFromCrossings(crossings: Crossing[], n: number): LapRange[] {
  const laps: LapRange[] = [];
  if (crossings.length === 0) return laps;
  const first = crossings[0].p;
  if (first > 1) laps.push({ label: 'Out', kind: 'out', number: null, pStart: 0, pEnd: first });
  for (let i = 0; i + 1 < crossings.length; i++) {
    laps.push({ label: String(i + 1), kind: 'timed', number: i + 1, pStart: crossings[i].p, pEnd: crossings[i + 1].p });
  }
  const last = crossings[crossings.length - 1].p;
  if (last < n - 2) laps.push({ label: 'In', kind: 'in', number: null, pStart: last, pEnd: n - 1 });

  // A "lap" far slower than the typical lap is usually a pit stop or a red flag.
  const lapTimes = crossings.slice(1).map((c, i) => c.time - crossings[i].time);
  const med = median(lapTimes);
  if (Number.isFinite(med)) {
    for (const l of laps) {
      if (l.kind === 'timed' && lapTimes[(l.number ?? 1) - 1] > med * 1.6) {
        l.kind = 'pit';
        l.label = `${l.label} (slow)`;
      }
    }
  }
  return laps;
}

export function singleRun(n: number): LapRange[] {
  return [{ label: 'Run', kind: 'run', number: null, pStart: 0, pEnd: n - 1 }];
}

/** Lap counts toward best/theoretical best. */
export function isTimed(kind: LapKind): boolean {
  return kind === 'timed';
}
