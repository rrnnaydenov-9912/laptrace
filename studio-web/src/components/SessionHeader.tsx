// Session title, track, lap/sector source and data-quality caveats.

import { fmtDate, fmtDist, fmtLap } from '../lib/format';
import type { SessionAnalysis, SessionRecord } from '../lib/types';

const LAP_SOURCE: Record<string, string> = {
  'track-gates': 'Laps from track start/finish line',
  'custom-gate': 'Laps from your start/finish line',
  csv: 'Laps from the CSV Lap column',
  single: 'No laps found — whole session as one run',
};
const SECTOR_SOURCE: Record<string, string> = {
  track: 'track split lines',
  virtual: 'auto splits at ⅓ and ⅔ of the lap',
  none: 'no sectors',
};

interface Props {
  rec: SessionRecord;
  a: SessionAnalysis;
}

export function SessionHeader({ rec, a }: Props) {
  const best = a.bestLapIndex != null ? a.laps[a.bestLapIndex] : null;
  return (
    <section className="session-head">
      <div className="sh-main">
        <h1>{rec.name}</h1>
        <p className="sh-meta">
          <span className={`track-pill ${a.track ? '' : 'unknown'}`}>{a.track ? a.track.name : 'Unknown track'}</span>
          <span>{fmtDate(rec.date)}</span>
          <span>{LAP_SOURCE[a.lapSource]}</span>
          <span>Sectors: {SECTOR_SOURCE[a.sectorSource]}</span>
        </p>
      </div>
      <div className="sh-kpis">
        <div><span>Best lap</span><b>{fmtLap(best?.time)}</b></div>
        <div><span>Theoretical</span><b>{fmtLap(a.theoreticalBest)}</b></div>
        <div><span>Timed laps</span><b>{a.laps.filter((l) => l.kind === 'timed').length}</b></div>
        <div><span>Lap length</span><b>{best ? fmtDist(best.length) : '—'}</b></div>
      </div>
      {!a.track && !rec.customGate && a.lapSource !== 'single' && (
        <p className="notice">Track not recognised. Laps come from the CSV; use <b>Set start/finish</b> on the map for gate-based timing.</p>
      )}
      {a.lapSource === 'single' && (
        <p className="notice">No laps found. Use <b>Set start/finish</b> on the map to draw a timing line across the track.</p>
      )}
      {a.lowRateGps && (
        <p className="caveat">
          Phone GPS (~{Math.max(1, Math.round(a.gpsHz))} Hz origin): lap and sector times are approximate, ±0.1–0.5 s.
        </p>
      )}
      {a.hasG && !rec.report.gAxesConfirmed && (
        <p className="caveat">G-force axes could not be confirmed from the column names — longitudinal/lateral may be swapped or inverted.</p>
      )}
    </section>
  );
}
