// Rule-based coaching notes for the focus lap.

import { cursor } from '../state/cursor';
import type { CoachTip, Consistency } from '../lib/coach';
import type { Workspace } from '../lib/workspace';

interface Props {
  ws: Workspace;
  tips: CoachTip[];
  isRef: boolean;
  focusLabel: string;
  cons: Consistency | null;
  lowRateGps: boolean;
}

export function CoachPanel({ ws, tips, isRef, focusLabel, cons, lowRateGps }: Props) {
  return (
    <section className="card coach">
      <header className="card-head"><h2>Coach</h2><span className="hint">Lap {focusLabel}{isRef ? ' · reference lap' : ' vs reference'}</span></header>
      {tips.length === 0 ? (
        <p className="empty">
          {isRef
            ? 'No other lap was clearly quicker in any corner. Add laps to the comparison to find more.'
            : 'No corner where this lap lost more than 0.05 s to the reference.'}
        </p>
      ) : (
        <ol className="tips">
          {tips.map((t) => {
            const c = ws.corners.find((x) => x.number === t.corner);
            return (
              <li key={t.corner} onClick={() => c && cursor.set({ s: c.sApex, time: null, src: 'corner' })}>
                <span className="tip-loss">{isRef ? '−' : '+'}{t.loss.toFixed(2)} s</span>
                <span>{t.text}</span>
              </li>
            );
          })}
        </ol>
      )}
      {cons && cons.lapCount >= 2 && (
        <div className="consistency">
          <h3>Consistency</h3>
          <p>
            Lap times vary by <b>±{cons.lapTimeSd!.toFixed(2)} s</b> (σ over {cons.lapCount} timed laps).
            {cons.lapTimeSd! < 0.5 ? ' Very consistent.' : cons.lapTimeSd! < 1.2 ? ' Reasonably consistent.' : ' Large spread — focus on repeating your best lines.'}
          </p>
          {cons.worstCorner && (
            <p>
              Least consistent: <b>corner {cons.worstCorner.corner}</b>, min speed σ {cons.worstCorner.sd.toFixed(1)} km/h.
            </p>
          )}
        </div>
      )}
      {lowRateGps && <p className="caveat">Phone GPS: corner times and losses carry roughly ±0.1–0.5 s of uncertainty; trust trends over single numbers.</p>}
    </section>
  );
}
