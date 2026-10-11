// Road drive: route coloured by speed or pedals, headline stats and a speed-over-time chart.

import { useEffect, useMemo, useRef } from 'react';
import uPlot from 'uplot';
import 'uplot/dist/uPlot.min.css';
import { driveStats } from '../lib/drive';
import { fmtDist, fmtDuration, fmtSpeedU, speedFactor, speedUnit } from '../lib/format';
import type { SessionAnalysis, SessionRecord } from '../lib/types';
import { TrackMap } from './TrackMap';

interface Props {
  rec: SessionRecord;
  a: SessionAnalysis;
  theme: 'light' | 'dark';
}

const NO_COLORS = new Map<string, string>();
const fmtG = (v: number | null) => (v == null ? '—' : `${v.toFixed(2)} g`);

function cssVar(name: string, fallback: string): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}

function SpeedChart({ rec, theme }: { rec: SessionRecord; theme: string }) {
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const host = el.current;
    const ch = rec.channels;
    if (!host || ch.t.length < 2) return;
    const t0 = ch.t[0];
    const k = speedFactor();
    const xs: number[] = [];
    const ys: (number | null)[] = [];
    for (let i = 0; i < ch.t.length; i++) {
      // A gap over 5 s breaks the line instead of drawing a straight ramp across it.
      if (i > 0 && ch.t[i] - ch.t[i - 1] > 5) { xs.push((ch.t[i - 1] - t0 + 0.01) / 60); ys.push(null); }
      xs.push((ch.t[i] - t0) / 60);
      ys.push(ch.speed[i] * k);
    }
    const grid = cssVar('--grid', 'rgba(128,128,128,.15)');
    const axis = cssVar('--muted', '#888');
    const axisCfg = { stroke: axis, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 }, font: '11px system-ui, sans-serif' };
    const height = 200;
    const u = new uPlot({
      width: host.clientWidth || 600,
      height,
      legend: { show: false },
      padding: [8, 8, 0, 0],
      cursor: { y: false, drag: { x: true, y: false, setScale: true } },
      scales: { x: { time: false } },
      axes: [
        { ...axisCfg, size: 28, values: (_u, v) => v.map((x) => `${Math.round(x)} min`) },
        { ...axisCfg, size: 46 },
      ],
      series: [{}, { stroke: cssVar('--accent', '#e5484d'), width: 1.5, fill: cssVar('--accent-soft', 'rgba(229,72,77,.12)'), points: { show: false } }],
    }, [xs, ys], host);
    const ro = new ResizeObserver(() => u.setSize({ width: host.clientWidth, height }));
    ro.observe(host);
    return () => { ro.disconnect(); u.destroy(); };
  }, [rec, theme]);
  return <div ref={el} className="chart" role="img" aria-label={`Speed over time in ${speedUnit()}`} />;
}

export function DriveView({ rec, a, theme }: Props) {
  const st = useMemo(() => driveStats(rec.channels), [rec]);
  const lap = a.laps[0] ?? null;
  const rows: [string, string][] = [
    ['Distance', fmtDist(st.distance)],
    ['Duration', fmtDuration(st.duration)],
    ['Moving time', fmtDuration(st.movingTime)],
    ['Average moving speed', fmtSpeedU(st.avgMovingSpeed)],
    ['Top speed', fmtSpeedU(st.maxSpeed)],
  ];
  if (st.maxLatG != null) {
    rows.push(['Peak cornering', fmtG(st.maxLatG)], ['Peak braking', fmtG(st.maxBrakeG)], ['Peak acceleration', fmtG(st.maxAccelG)]);
  }
  return (
    <>
      <div className="grid-top">
        <section className="card map-card">
          <TrackMap
            ws={null}
            focus={lap}
            overlays={[]}
            colors={NO_COLORS}
            startFinish={null}
            sectorGates={[]}
            center={a.center}
            fitKey={rec.id}
            canDefineGate={false}
            onDefineGate={() => {}}
            onResetGate={null}
          />
        </section>
        <section className="card drive-stats" aria-label="Drive summary">
          <h2>Road drive</h2>
          <dl>
            {rows.map(([k, v]) => (
              <div key={k}><dt>{k}</dt><dd>{v}</dd></div>
            ))}
          </dl>
          <p className="hint">Road drives have no laps, so lap times and the coach are hidden. Switch the map to pedals to see where you braked and accelerated.</p>
        </section>
      </div>
      <section className="card">
        <h2 className="card-title">Speed ({speedUnit()})</h2>
        <SpeedChart rec={rec} theme={theme} />
      </section>
    </>
  );
}
