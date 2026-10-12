// Lap time against oil and coolant temperature across the stint: does the car fade as it heats up?

import type { Stint } from '../lib/car';
import { fmtLap } from '../lib/format';

const W = 640, H = 220, L = 52, R = 48, T = 14, B = 30;

function scale(vals: number[], pad: number): [number, number] {
  const lo = Math.min(...vals), hi = Math.max(...vals);
  return hi - lo < 1e-6 ? [lo - pad, hi + pad] : [lo - (hi - lo) * 0.1, hi + (hi - lo) * 0.1];
}

export function StintChart({ stint }: { stint: Stint }) {
  const rows = stint.rows;
  const x = (i: number) => L + (rows.length === 1 ? 0 : (i / (rows.length - 1)) * (W - L - R));
  const [t0, t1] = scale(rows.map((r) => r.time), 0.5);
  const temps = rows.flatMap((r) => [r.oil, r.coolant]).filter((v): v is number => v != null);
  const [c0, c1] = scale(temps, 2);
  const yT = (v: number) => T + (1 - (v - t0) / (t1 - t0)) * (H - T - B);
  const yC = (v: number) => T + (1 - (v - c0) / (c1 - c0)) * (H - T - B);
  const line = (pick: (i: number) => number | null, y: (v: number) => number) =>
    rows.map((_, i) => pick(i)).map((v, i) => (v == null ? null : `${x(i).toFixed(1)},${y(v).toFixed(1)}`)).filter(Boolean).join(' ');
  const ticks = (a: number, b: number) => [0, 0.5, 1].map((f) => a + (b - a) * f);

  let verdict: string | null = null;
  if (stint.secPer10C != null && stint.tempChannel) {
    const s = stint.secPer10C, name = stint.tempChannel;
    verdict = Math.abs(s) < 0.1
      ? `Lap times held steady as the ${name} warmed up.`
      : s > 0
        ? `Laps got about ${s.toFixed(2)} s slower for every 10 °C of ${name}. Heat may be costing power or grip; try a cool-down lap mid-stint.`
        : `Laps got about ${(-s).toFixed(2)} s quicker for every 10 °C of ${name}, so the car and tyres were still coming in.`;
  }

  return (
    <section className="card stint">
      <header className="card-head"><h2>Stint</h2><span className="hint">Lap time against the hottest oil and coolant of each lap</span></header>
      <div className="stint-chart">
        <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Lap time and temperatures by lap">
          {ticks(t0, t1).map((v) => (
            <g key={'t' + v}>
              <line x1={L} x2={W - R} y1={yT(v)} y2={yT(v)} className="grid" />
              <text x={L - 6} y={yT(v) + 4} textAnchor="end" className="ax">{fmtLap(v, 1)}</text>
            </g>
          ))}
          {ticks(c0, c1).map((v) => <text key={'c' + v} x={W - R + 6} y={yC(v) + 4} className="ax">{Math.round(v)}°</text>)}
          {rows.map((r, i) => <text key={r.key} x={x(i)} y={H - 10} textAnchor="middle" className="ax">{r.label}</text>)}
          <polyline points={line((i) => rows[i].coolant, yC)} className="s-coolant" fill="none" />
          <polyline points={line((i) => rows[i].oil, yC)} className="s-oil" fill="none" />
          <polyline points={line((i) => rows[i].time, yT)} className="s-time" fill="none" />
          {rows.map((r, i) => <circle key={r.key} cx={x(i)} cy={yT(r.time)} r={3.5} className="s-time-dot" />)}
        </svg>
      </div>
      <ul className="stint-legend">
        <li><i className="s-time" />Lap time</li>
        <li><i className="s-oil" />Oil °C</li>
        <li><i className="s-coolant" />Coolant °C</li>
      </ul>
      {verdict && <p className="stint-verdict">{verdict}</p>}
    </section>
  );
}
