// What the OBD data says about the driving: shift points, full throttle, coasting, temperatures.

import type { CarSummary } from '../lib/car';

const fmt = (v: number | null, unit: string, step = 1) => (v == null ? '–' : `${Math.round(v / step) * step}${unit}`);

export function CarPanel({ summary, refLabel }: { summary: CarSummary; refLabel: string }) {
  const r = summary.ref;
  return (
    <section className="card car">
      <header className="card-head"><h2>Car</h2><span className="hint">Lap {refLabel} · from the OBD reader</span></header>
      <dl className="car-stats">
        <div><dt>Max revs</dt><dd>{fmt(r.maxRpm, ' rpm', 50)}</dd></div>
        <div><dt>Upshift at</dt><dd>{fmt(r.shiftRpm, ' rpm', 50)}</dd></div>
        <div><dt>Flat out</dt><dd>{fmt(r.fullThrottlePct, '%')}</dd></div>
        <div><dt>Coasting</dt><dd>{r.coastSeconds == null ? '–' : `${r.coastSeconds.toFixed(1)} s`}</dd></div>
        <div><dt>Coolant max</dt><dd>{fmt(r.coolantMax, ' °C')}</dd></div>
        <div><dt>Oil max</dt><dd>{fmt(r.oilMax, ' °C')}</dd></div>
      </dl>
      {summary.advice.length > 0 && (
        <ul className="car-advice">
          {summary.advice.map((a) => <li key={a.topic + a.text} className={a.level === 'warn' ? 'warn' : undefined}>{a.text}</li>)}
        </ul>
      )}
    </section>
  );
}
