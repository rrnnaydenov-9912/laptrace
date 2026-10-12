// Rule-based coaching notes for the focus lap.

import { cursor } from '../state/cursor';
import { speedFactor, speedUnit } from '../lib/format';
import type { CoachTip, Consistency } from '../lib/coach';
import type { Workspace } from '../lib/workspace';
import { fastestThrough } from '../lib/cornerLines';
import { CornerLines } from './CornerLines';

interface Props {
  ws: Workspace;
  tips: CoachTip[];
  isRef: boolean;
  focusLabel: string;
  cons: Consistency | null;
  lowRateGps: boolean;
  focusKey: string;
  labels: Map<string, string>;
  onExplain: (corner: number, vsKey: string | null) => void;
}

export function CoachPanel({ ws, tips, isRef, focusLabel, cons, lowRateGps, focusKey, labels, onExplain }: Props) {
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
            const vsKey = isRef ? t.vsKey ?? null : ws.refKey;
            return (
              <li key={t.corner}>
                <button type="button" className="tip-main" onClick={() => c && cursor.set({ s: c.sApex, time: null, src: 'corner' })}>
                  <span className="tip-loss">{isRef ? '−' : '+'}{t.loss.toFixed(2)} s</span>
                  <span>{t.text}</span>
                </button>
                {c && (
                  <button
                    type="button"
                    className="cl-thumb-btn"
                    onClick={() => { cursor.set({ s: c.sApex, time: null, src: 'corner' }); onExplain(t.corner, vsKey); }}
                    title={`Compare the lines through corner ${t.corner}`}
                  >
                    <CornerLines ws={ws} corner={c} keys={[focusKey, vsKey]} variant="thumb"
                      label={`Corner ${t.corner}: lap ${focusLabel}${vsKey ? ` and lap ${labels.get(vsKey) ?? vsKey}` : ''}`} />
                    <span>Compare lines</span>
                  </button>
                )}
              </li>
            );
          })}
        </ol>
      )}
      {ws.aligned.size >= 2 && ws.corners.length > 0 && (
        <div className="cl-strip">
          <h3>Your lines, corner by corner</h3>
          <p className="hint">Lap {focusLabel} against the quickest other lap through each corner. Open one to replay both.</p>
          <ul>
            {ws.corners.map((c) => {
              const vsKey = fastestThrough(ws, c.number, focusKey) ?? (focusKey !== ws.refKey ? ws.refKey : null);
              const vsLabel = vsKey ? labels.get(vsKey) ?? vsKey : '';
              return (
                <li key={c.number}>
                  <button
                    type="button"
                    className="cl-thumb-btn"
                    onClick={() => { cursor.set({ s: c.sApex, time: null, src: 'corner' }); onExplain(c.number, vsKey); }}
                    title={`Compare the lines through turn ${c.number}`}
                  >
                    <CornerLines ws={ws} corner={c} keys={[focusKey, vsKey]} variant="thumb"
                      label={`Turn ${c.number}: lap ${focusLabel}${vsKey ? ` and lap ${vsLabel}` : ''}`} />
                    <span>T{c.number}{vsKey ? ` · vs lap ${vsLabel}` : ''}</span>
                  </button>
                </li>
              );
            })}
          </ul>
        </div>
      )}
      {cons && cons.lapCount >= 2 && (
        <div className="consistency">
          <h3>Consistency{cons.score != null && <span className="cons-score" title="Lap-time spread (60%) and brake-point spread (40%)">{cons.score}<small>/100</small></span>}</h3>
          <p>
            Lap times vary by <b>±{cons.lapTimeSd!.toFixed(2)} s</b> (σ over {cons.lapCount} timed laps).
            {cons.lapTimeSd! < 0.5 ? ' Very consistent.' : cons.lapTimeSd! < 1.2 ? ' Reasonably consistent.' : ' Large spread — focus on repeating your best lines.'}
          </p>
          {cons.worstCorner && (
            <p>
              Least consistent: <b>corner {cons.worstCorner.corner}</b>, min speed σ {(cons.worstCorner.sd * speedFactor()).toFixed(1)} {speedUnit()}.
            </p>
          )}
          {cons.brakeSdMedian != null && cons.worstBrakeCorner && (
            <p>
              Brake points move by <b>±{cons.brakeSdMedian.toFixed(0)} m</b> on a typical corner; most at <b>corner {cons.worstBrakeCorner.corner}</b> (±{cons.worstBrakeCorner.sd.toFixed(0)} m).
              {cons.worstBrakeCorner.sd > 10 ? ' Pick a fixed marker there and brake at it every lap.' : ''}
            </p>
          )}
        </div>
      )}
      {lowRateGps && <p className="caveat">Phone GPS: corner times and losses carry roughly ±0.1–0.5 s of uncertainty; trust trends over single numbers.</p>}
    </section>
  );
}
