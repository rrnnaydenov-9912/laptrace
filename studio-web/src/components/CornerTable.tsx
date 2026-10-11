// Per-corner figures for the focus lap vs the reference, plus session consistency.

import { cursor } from '../state/cursor';
import { fmtDelta, fmtSpeed, speedFactor, speedUnit } from '../lib/format';
import type { Workspace } from '../lib/workspace';
import type { Consistency } from '../lib/coach';
import type { CornerStats } from '../lib/corners';

interface Props {
  ws: Workspace;
  focusKey: string;
  focusLabel: string;
  cons: Consistency | null;
}

function brakeDelta(st: CornerStats | undefined, rs: CornerStats | undefined, isRef: boolean): string {
  if (isRef || !st?.valid || !rs?.valid || !Number.isFinite(st.brakeS) || !Number.isFinite(rs.brakeS)) return '—';
  const d = Math.round(st.brakeS - rs.brakeS);
  return d === 0 ? '0 m' : `${d > 0 ? '+' : '−'}${Math.abs(d)} m`;
}

export function CornerTable({ ws, focusKey, focusLabel, cons }: Props) {
  const stats = ws.stats.get(focusKey) ?? [];
  const refStats = ws.stats.get(ws.refKey) ?? [];
  const isRef = focusKey === ws.refKey;
  const u = speedUnit();
  if (ws.corners.length === 0) {
    return (
      <section className="card corners">
        <header className="card-head"><h2>Corners</h2></header>
        <p className="empty">No corners detected on the reference lap.</p>
      </section>
    );
  }
  return (
    <section className="card corners">
      <header className="card-head"><h2>Corners</h2><span className="hint">Lap {focusLabel}{isRef ? ' (reference)' : ' vs reference'}</span></header>
      <div className="table-scroll">
        <table className="data">
          <thead>
            <tr>
              <th>#</th>
              <th title={`Entry speed, ${u}`}>Entry</th>
              <th title={`Minimum speed, ${u}`}>Min</th>
              <th title={`Reference minimum speed, ${u}`}>Ref min</th>
              <th title={`Exit speed, ${u}`}>Exit</th>
              <th title="Brake point vs the reference, metres. Positive = braked later">Brake Δ</th>
              <th title="Time between corner start and end, s">Time</th>
              <th title="Time lost in the corner zone vs the reference, s">Loss</th>
              <th title={`Standard deviation of min speed across timed laps, ${u}`}>σ min</th>
            </tr>
          </thead>
          <tbody>
            {ws.corners.map((c, i) => {
              const st = stats[i];
              const rs = refStats[i];
              const sd = cons?.perCornerSd.find((p) => p.corner === c.number)?.sd;
              const ok = st?.valid;
              return (
                <tr key={c.number} className="clickable" onClick={() => cursor.set({ s: c.sApex, time: null, src: 'corner' })}>
                  <td><span className="corner-badge">{c.number}</span> <span className="muted">{c.direction}</span></td>
                  <td>{ok ? fmtSpeed(st.entrySpeed) : '—'}</td>
                  <td><b>{ok ? fmtSpeed(st.minSpeed) : '—'}</b></td>
                  <td className="muted">{rs?.valid ? fmtSpeed(rs.minSpeed) : '—'}</td>
                  <td>{ok ? fmtSpeed(st.exitSpeed) : '—'}</td>
                  <td className="muted">{brakeDelta(st, rs, isRef)}</td>
                  <td>{ok ? st.timeInCorner.toFixed(2) : '—'}</td>
                  <td className={ok && !isRef ? (st.lossVsRef > 0.02 ? 'neg' : st.lossVsRef < -0.02 ? 'pos' : '') : ''}>
                    {ok && !isRef ? fmtDelta(st.lossVsRef, 2) : '—'}
                  </td>
                  <td className="muted">{sd != null ? (sd * speedFactor()).toFixed(1) : '—'}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
