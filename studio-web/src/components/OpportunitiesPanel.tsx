// "Where's the time": target lap, best three in a row, and the corners with the most to gain.

import { cursor } from '../state/cursor';
import { fmtDelta, fmtLap, fmtSpeed, speedUnit } from '../lib/format';
import { causeLabel, type Opportunity } from '../lib/insights';
import type { Workspace } from '../lib/workspace';
import { CornerLines } from './CornerLines';

interface Props {
  ws: Workspace;
  refLabel: string;
  refTime: number;
  opps: Opportunity[];
  target: { time: number; gain: number; corners: number[] } | null;
  bestThree: { total: number; avg: number; from: string; to: string } | null;
  lowRateGps: boolean;
  onExplain: (corner: number, vsKey: string | null) => void;
}

function causeValues(o: Opportunity, sApex: number): string | null {
  if (o.refValue == null || o.bestValue == null) return null;
  if (o.cause === 'minSpeed' || o.cause === 'exit') return `${fmtSpeed(o.refValue)} → ${fmtSpeed(o.bestValue)} ${speedUnit()}`;
  if (o.cause === 'braking') return `braking ${Math.round(sApex - o.refValue)} m → ${Math.round(sApex - o.bestValue)} m before the slowest point`;
  if (o.cause === 'throttle') return `throttle ${Math.round(o.refValue - sApex)} m → ${Math.round(o.bestValue - sApex)} m after the slowest point`;
  return null;
}

export function OpportunitiesPanel({ ws, refLabel, refTime, opps, target, bestThree, lowRateGps, onExplain }: Props) {
  const top = opps.slice(0, 6);
  return (
    <section className="card opps">
      <header className="card-head"><h2>Where's the time</h2><span className="hint">vs lap {refLabel}</span></header>
      <div className="opps-kpis">
        <div><span>Reference</span><b>{fmtLap(refTime)}</b></div>
        <div>
          <span>Target lap</span>
          <b>{target && target.gain > 0 ? fmtLap(target.time) : '—'}</b>
          {target && target.gain > 0 && <small>{fmtDelta(-target.gain, 2)} from {target.corners.length} corner{target.corners.length === 1 ? '' : 's'}</small>}
        </div>
        <div>
          <span>Best 3 in a row</span>
          <b>{bestThree ? fmtLap(bestThree.avg) : '—'}</b>
          {bestThree && <small>avg, laps {bestThree.from}–{bestThree.to}</small>}
        </div>
      </div>
      {top.length === 0 ? (
        <p className="empty">None of your other laps was clearly quicker than lap {refLabel} in any corner.</p>
      ) : (
        <ol className="opp-list">
          {top.map((o) => {
            const c = ws.corners.find((x) => x.number === o.corner);
            const vals = c ? causeValues(o, c.sApex) : null;
            return (
              <li key={o.corner}>
                <button type="button" onClick={() => c && cursor.set({ s: c.sApex, time: null, src: 'opps' })}>
                  <span className="opp-corner">T{o.corner}</span>
                  <span className="opp-text">
                    <b>{o.gain.toFixed(2)} s</b> available, shown on lap {o.fromLabel}
                    <small>Difference: {causeLabel(o.cause)}{vals ? ` (${vals})` : ''}</small>
                  </span>
                </button>
                {c && (
                  <button
                    type="button"
                    className="cl-thumb-btn"
                    onClick={() => { cursor.set({ s: c.sApex, time: null, src: 'opps' }); onExplain(o.corner, o.fromKey); }}
                    title={`Compare the lines through corner ${o.corner}`}
                  >
                    <CornerLines ws={ws} corner={c} keys={[ws.refKey, o.fromKey]} variant="thumb"
                      label={`Corner ${o.corner}: lap ${refLabel} and lap ${o.fromLabel}`} />
                    <span>Compare lines</span>
                  </button>
                )}
              </li>
            );
          })}
        </ol>
      )}
      <p className="footnote">The target adds up the three biggest gains your own laps already proved. {lowRateGps ? 'Phone GPS: treat gains under 0.2 s as noise.' : ''}</p>
    </section>
  );
}
