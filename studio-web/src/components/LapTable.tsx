// Lap list with sectors, deltas, overlay selection and reference choice.

import { fmtDelta, fmtLap, fmtSpeed } from '../lib/format';
import type { SessionAnalysis } from '../lib/types';

export interface LapGroup {
  title: string;
  analysis: SessionAnalysis;
  removable: boolean;
}

interface Props {
  groups: LapGroup[];
  selected: string[];
  colors: Map<string, string>;
  refKey: string | null;
  focusKey: string | null;
  maxSelected: number;
  onToggle: (key: string) => void;
  onRef: (key: string) => void;
  onFocus: (key: string) => void;
  onRemoveGroup: (sessionId: string) => void;
}

export function LapTable(p: Props) {
  const nSec = Math.max(0, ...p.groups.map((g) => (g.analysis.bestSectors ? g.analysis.bestSectors.length : 0)));
  return (
    <section className="card laps">
      <header className="card-head">
        <h2>Laps</h2>
        <span className="hint">{p.selected.length}/{p.maxSelected} overlaid · ★ = reference</span>
      </header>
      <div className="table-scroll">
        <table className="data laps-table">
          <thead>
            <tr>
              <th aria-label="Overlay" />
              <th aria-label="Reference" />
              <th>Lap</th>
              <th>Time</th>
              {Array.from({ length: nSec }, (_, i) => <th key={i}>S{i + 1}</th>)}
              <th title="Delta to the session's best lap">Δ best</th>
              <th title="Max speed, km/h">Vmax</th>
              <th title="Min speed, km/h">Vmin</th>
            </tr>
          </thead>
          {p.groups.map((g) => {
            const a = g.analysis;
            const best = a.bestLapIndex != null ? a.laps[a.bestLapIndex].time : null;
            return (
              <tbody key={a.sessionId}>
                {p.groups.length > 1 && (
                  <tr className="group-row">
                    <td colSpan={7 + nSec}>
                      {g.title}
                      {g.removable && (
                        <button type="button" className="link" onClick={() => p.onRemoveGroup(a.sessionId)}>remove</button>
                      )}
                    </td>
                  </tr>
                )}
                {a.laps.map((lap) => {
                  const timed = lap.kind === 'timed';
                  const sel = p.selected.includes(lap.key);
                  const isBest = lap.index === a.bestLapIndex;
                  const disabled = !sel && p.selected.length >= p.maxSelected;
                  return (
                    <tr
                      key={lap.key}
                      className={`clickable ${timed ? '' : 'untimed'} ${lap.key === p.focusKey ? 'focus' : ''}`}
                      onClick={() => p.onFocus(lap.key)}
                    >
                      <td onClick={(e) => e.stopPropagation()}>
                        <label className="swatch-check" title={disabled ? `Up to ${p.maxSelected} laps` : 'Overlay this lap'}>
                          <input type="checkbox" aria-label={`Overlay lap ${lap.label}`} checked={sel} disabled={disabled} onChange={() => p.onToggle(lap.key)} />
                          <i style={{ background: sel ? p.colors.get(lap.key) : 'transparent' }} />
                        </label>
                      </td>
                      <td onClick={(e) => e.stopPropagation()}>
                        <button
                          type="button"
                          className={`star ${p.refKey === lap.key ? 'on' : ''}`}
                          title="Use as reference"
                          aria-label={`Use lap ${lap.label} as reference`}
                          onClick={() => p.onRef(lap.key)}
                          disabled={lap.t.length < 2}
                        >★</button>
                      </td>
                      <td>
                        <b>{lap.label}</b>
                        {isBest && <span className="tag tag--best">best</span>}
                      </td>
                      <td className={isBest ? 'best-lap' : ''}>{fmtLap(lap.time)}</td>
                      {Array.from({ length: nSec }, (_, i) => {
                        const v = lap.sectors?.[i];
                        const bestSec = a.bestSectors?.[i];
                        const isBestSec = timed && v != null && bestSec != null && Math.abs(v - bestSec) < 1e-6;
                        return <td key={i} className={isBestSec ? 'best-sector' : ''}>{v != null && timed ? fmtLap(v, 2) : '—'}</td>;
                      })}
                      <td className={timed && best != null && lap.time - best > 0 ? 'neg' : ''}>
                        {timed && best != null ? (isBest ? '—' : fmtDelta(lap.time - best, 2)) : ''}
                      </td>
                      <td>{fmtSpeed(lap.maxSpeed)}</td>
                      <td>{fmtSpeed(lap.minSpeed)}</td>
                    </tr>
                  );
                })}
                {a.theoreticalBest != null && (
                  <tr className="theoretical">
                    <td colSpan={3}>Theoretical best</td>
                    <td className="best-sector">{fmtLap(a.theoreticalBest)}</td>
                    {Array.from({ length: nSec }, (_, i) => <td key={i}>{a.bestSectors?.[i] != null ? fmtLap(a.bestSectors[i], 2) : ''}</td>)}
                    <td>{best != null ? fmtDelta(a.theoreticalBest - best, 2) : ''}</td>
                    <td colSpan={2} />
                  </tr>
                )}
              </tbody>
            );
          })}
        </table>
      </div>
      <p className="footnote">Out, in and pit laps are shown but never count as best. Click a row to focus it on the map, G-G and coach.</p>
    </section>
  );
}
