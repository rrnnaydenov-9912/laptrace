// Per-corner figures for the focus lap vs the reference, plus session consistency.

import { cursor } from '../state/cursor';
import { fmtDelta, fmtSpeed } from '../lib/format';
import type { Workspace } from '../lib/workspace';
import type { Consistency } from '../lib/coach';

interface Props {
  ws: Workspace;
  focusKey: string;
  focusLabel: string;
  cons: Consistency | null;
}

export function CornerTable({ ws, focusKey, focusLabel, cons }: Props) {
  const stats = ws.stats.get(focusKey) ?? [];
  const refStats = ws.stats.get(ws.refKey) ?? [];
  const isRef = focusKey === ws.refKey;
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
              <th title="Entry speed, km/h">Entry</th>
              <th title="Minimum speed, km/h">Min</th>
              <th title="Reference minimum speed, km/h">Ref min</th>
              <th title="Exit speed, km/h">Exit</th>
              <th title="Time between corner start and end, s">Time</th>
              <th title="Time lost in the corner zone vs the reference, s">Loss</th>
              <th title="Standard deviation of min speed across timed laps, km/h">σ min</th>
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
                  <td>{ok ? st.timeInCorner.toFixed(2) : '—'}</td>
                  <td className={ok && !isRef ? (st.lossVsRef > 0.02 ? 'neg' : st.lossVsRef < -0.02 ? 'pos' : '') : ''}>
                    {ok && !isRef ? fmtDelta(st.lossVsRef, 2) : '—'}
                  </td>
                  <td className="muted">{sd != null ? sd.toFixed(1) : '—'}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
