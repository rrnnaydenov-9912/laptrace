// One corner, two lines: the coached lap against a quicker lap (the reference, or the
// fastest lap through that corner). Shows where each braked, how slow each got, where each
// picked up the throttle, and replays both through the corner so the gap is visible.

import { useEffect, useMemo, useState } from 'react';
import { cursor } from '../state/cursor';
import { compareSentence, fastestThrough } from '../lib/cornerLines';
import { fmtSpeedU, speedFactor, speedUnit } from '../lib/format';
import type { CornerStats } from '../lib/corners';
import type { Workspace } from '../lib/workspace';
import { CornerLines } from './CornerLines';

export interface ExplainRequest { corner: number; vsKey: string | null; n: number }

interface Props {
  ws: Workspace;
  focusKey: string;
  focusLabel: string;
  labels: Map<string, string>;
  request: ExplainRequest | null;
}

const FASTEST = '__fastest';

const fin = (v: number | undefined | null): v is number => typeof v === 'number' && Number.isFinite(v);
const metres = (v: number) => `${Math.round(v)} m`;

export function CornerExplainer({ ws, focusKey, focusLabel, labels, request }: Props) {
  const [num, setNum] = useState<number>(ws.corners[0]?.number ?? 0);
  // Coaching a lap other than the reference: compare it with the reference by default.
  const defaultVs = focusKey !== ws.refKey ? ws.refKey : FASTEST;
  const [vs, setVs] = useState<string>(defaultVs);
  useEffect(() => setVs(defaultVs), [defaultVs]);

  useEffect(() => {
    if (!request) return;
    setNum(request.corner);
    setVs(request.vsKey ?? FASTEST);
  }, [request]);

  const corner = ws.corners.find((c) => c.number === num) ?? ws.corners[0];
  const others = useMemo(() => [...ws.aligned.keys()].filter((k) => k !== focusKey), [ws, focusKey]);
  const vsKey = !corner ? null
    : vs === FASTEST ? fastestThrough(ws, corner.number, focusKey)
    : ws.aligned.has(vs) && vs !== focusKey ? vs : null;

  if (!corner) return null;
  const statsOf = (k: string | null): CornerStats | null => (k ? ws.stats.get(k)?.find((c) => c.corner === corner.number) ?? null : null);
  const a = statsOf(focusKey), b = statsOf(vsKey);
  const vsLabel = vsKey ? labels.get(vsKey) ?? vsKey : '';
  const unit = speedUnit();
  const speedDiff = (v: number) => `${(v * speedFactor()).toFixed(0)} ${unit}`;

  const rows: [string, (s: CornerStats) => string, (s: CornerStats) => number | null, 'higher' | 'lower' | 'later' | 'sooner'][] = [
    ['Speed on entry', (s) => fmtSpeedU(s.entrySpeed), (s) => s.entrySpeed, 'higher'],
    ['Braking starts', (s) => (fin(s.brakeS) ? `${metres(s.minS - s.brakeS)} before slowest` : '—'), (s) => (fin(s.brakeS) ? s.brakeS : null), 'later'],
    ['Slowest point', (s) => fmtSpeedU(s.minSpeed), (s) => s.minSpeed, 'higher'],
    ['Throttle back on', (s) => (fin(s.throttleS) ? `${metres(s.throttleS - s.minS)} after slowest` : '—'), (s) => (fin(s.throttleS) ? s.throttleS : null), 'sooner'],
    ['Speed on exit', (s) => fmtSpeedU(s.exitSpeed), (s) => s.exitSpeed, 'higher'],
    ['Time through the corner', (s) => `${s.zoneTime.toFixed(2)} s`, (s) => s.zoneTime, 'lower'],
  ];
  // Only mark a winner when the difference shows at the precision on screen.
  const better = (dir: string, x: number | null, y: number | null) => {
    if (x == null || y == null) return false;
    const eps = dir === 'lower' ? 0.005 : dir === 'higher' ? 0.5 / speedFactor() : 0.5;
    return dir === 'higher' || dir === 'later' ? x > y + eps : x < y - eps;
  };
  const okA = !!a?.valid, okB = !!b?.valid;

  return (
    <section className="card explainer" id="corner-explainer">
      <header className="card-head">
        <h2>Corner by corner</h2>
      </header>
      <div className="ex-controls">
        <label htmlFor="explainer-corner">Corner</label>
        <select
          id="explainer-corner"
          value={corner.number}
          onChange={(e) => {
            const n = Number(e.target.value); setNum(n);
            const c = ws.corners.find((x) => x.number === n);
            if (c) cursor.set({ s: c.sApex, time: null, src: 'explainer' });
          }}
        >
          {ws.corners.map((c) => <option key={c.number} value={c.number}>Turn {c.number} ({c.direction === 'L' ? 'left' : 'right'}, {Math.round(c.angle)}°)</option>)}
        </select>
        <label htmlFor="explainer-vs">Compare with</label>
        <select id="explainer-vs" value={vs} onChange={(e) => setVs(e.target.value)}>
          <option value={FASTEST}>Fastest lap in this corner</option>
          {others.map((k) => <option key={k} value={k}>Lap {labels.get(k) ?? k}{k === ws.refKey ? ' (reference)' : ''}</option>)}
        </select>
      </div>
      <ul className="ex-legend" aria-label="Legend">
        <li className="cl-a"><i className="sw" />Lap {focusLabel}</li>
        {vsKey && <li className="cl-b"><i className="sw" />Lap {vsLabel}</li>}
        <li><i className="sh sh-brake" />brake</li>
        <li><i className="sh sh-slow" />slowest</li>
        <li><i className="sh sh-throttle" />throttle</li>
      </ul>
      <CornerLines
        ws={ws}
        corner={corner}
        keys={[focusKey, vsKey]}
        variant="full"
        label={`Turn ${corner.number}: lap ${focusLabel}${vsKey ? ` and lap ${vsLabel}` : ''} with their brake, slowest and throttle points`}
      />
      {okA && okB && vsKey ? (
        <>
          <p className="ex-verdict">{compareSentence(a!, b!, vsLabel, speedDiff)}</p>
          <div className="ex-table-wrap">
            <table className="ex-table">
              <thead><tr><th scope="col" /><th scope="col" className="cl-a">Lap {focusLabel}</th><th scope="col" className="cl-b">Lap {vsLabel}</th></tr></thead>
              <tbody>
                {rows.map(([name, show, val, dir]) => (
                  <tr key={name}>
                    <th scope="row">{name}</th>
                    <td className={better(dir, val(a!), val(b!)) ? 'win' : ''}>{show(a!)}</td>
                    <td className={better(dir, val(b!), val(a!)) ? 'win' : ''}>{show(b!)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      ) : (
        <p className="hint">
          {!okA ? `No clean data for lap ${focusLabel} in turn ${corner.number}.`
            : !vsKey ? 'No other lap has clean data in this corner yet. Add laps to the comparison.'
            : `No clean data for lap ${vsLabel} in turn ${corner.number}.`}
        </p>
      )}
      <p className="footnote">
        The band is the track as driven on your reference lap. Phone GPS lines are accurate to a couple of metres, so read the shape of the line rather than its exact position.
        Brake in a straight line, turn in once most of the braking is done, and pick up the throttle once you can see the exit.
      </p>
    </section>
  );
}
