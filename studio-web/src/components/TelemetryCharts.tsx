// Stacked uPlot charts vs reference distance: speed, time delta, longitudinal g,
// lateral g. Shared cursor + synced zoom + lap playback.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import uPlot from 'uplot';
import 'uplot/dist/uPlot.min.css';
import { cursor, useCursor } from '../state/cursor';
import { distanceAtTime, sampleAt, type AlignedLap } from '../lib/alignment';
import type { Workspace } from '../lib/workspace';
import { fmtDelta, fmtDist, fmtSpeed, speedFactor, speedUnit } from '../lib/format';
import type { LapData } from '../lib/types';

interface Props {
  ws: Workspace;
  laps: LapData[];
  colors: Map<string, string>;
  labels: Map<string, string>;
  focusKey: string | null;
  hasG: boolean;
  theme: string;
}

type Channel = 'speed' | 'delta' | 'gLong' | 'gLat';
const PANELS: { id: Channel; title: string; unit: string; height: number }[] = [
  { id: 'speed', title: 'Speed', unit: 'km/h', height: 190 },
  { id: 'delta', title: 'Time delta vs reference', unit: 's', height: 130 },
  { id: 'gLong', title: 'Longitudinal g', unit: 'g', height: 120 },
  { id: 'gLat', title: 'Lateral g', unit: 'g', height: 120 },
];

function cssVar(name: string, fallback: string): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}

function toSeries(arr: ArrayLike<number> | null | undefined, n: number, k = 1): (number | null)[] {
  const out = new Array<number | null>(n);
  for (let i = 0; i < n; i++) {
    const v = arr ? arr[i] : NaN;
    out[i] = Number.isFinite(v) ? v * k : null;
  }
  return out;
}

function Panel({
  id, title, unit, height, ws, laps, colors, focusKey, theme, xRange, onZoom,
}: {
  id: Channel; title: string; unit: string; height: number; ws: Workspace; laps: AlignedLap[];
  colors: Map<string, string>; focusKey: string | null; theme: string;
  xRange: [number, number] | null; onZoom: (r: [number, number] | null) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const plot = useRef<uPlot | null>(null);
  const zoomRef = useRef(onZoom);
  useEffect(() => {
    zoomRef.current = onZoom;
  }, [onZoom]);
  const applying = useRef(false);
  const chartId = `chart-${id}`;

  useEffect(() => {
    const host = el.current;
    if (!host) return;
    const n = ws.ref.s.length;
    const xs = Array.from(ws.ref.s);
    const data: uPlot.AlignedData = [xs, ...laps.map((l) => toSeries(l[id], n, id === 'speed' ? speedFactor() : 1))];
    const grid = cssVar('--grid', 'rgba(128,128,128,.15)');
    const axis = cssVar('--muted', '#888');
    const axisCfg = { stroke: axis, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 }, font: '11px system-ui, sans-serif' };
    const opts: uPlot.Options = {
      width: host.clientWidth || 600,
      height,
      legend: { show: false },
      padding: [8, 8, 0, 0],
      cursor: {
        y: false,
        drag: { x: true, y: false, setScale: true },
        points: { size: 6 },
      },
      scales: { x: { time: false }, y: id === 'delta' || id === 'gLat' || id === 'gLong' ? { range: (_u, lo, hi) => {
        if (lo == null || hi == null) return [-1, 1];
        const m = Math.max(Math.abs(lo), Math.abs(hi), id === 'delta' ? 0.2 : 0.3) * 1.1;
        return [-m, m];
      } } : {} },
      axes: [
        { ...axisCfg, size: 28, values: (_u, v) => v.map((x) => (x >= 1000 ? `${(x / 1000).toFixed(1)}k` : `${x}`)) },
        { ...axisCfg, size: 46, label: undefined },
      ],
      series: [
        {},
        ...laps.map((l) => ({
          stroke: colors.get(l.key) ?? '#888',
          width: l.key === focusKey ? 2 : 1.25,
          spanGaps: false,
          points: { show: false },
        })),
      ],
      hooks: {
        setCursor: [(u) => {
          if (applying.current) return;
          const idx = u.cursor.idx;
          if (idx == null || u.cursor.left == null || u.cursor.left < 0) return;
          cursor.set({ s: u.posToVal(u.cursor.left, 'x'), time: null, src: chartId });
        }],
        setScale: [(u, key) => {
          if (key !== 'x' || applying.current) return;
          const { min, max } = u.scales.x;
          if (min == null || max == null) return;
          const full = min <= xs[0] + 0.5 && max >= xs[xs.length - 1] - 0.5;
          zoomRef.current(full ? null : [min, max]);
        }],
      },
    };
    const u = new uPlot(opts, data, host);
    plot.current = u;
    const ro = new ResizeObserver(() => u.setSize({ width: host.clientWidth, height }));
    ro.observe(host);
    const onLeave = () => setTimeout(() => apply(), 0);
    host.addEventListener('mouseleave', onLeave);
    const onDbl = () => zoomRef.current(null);
    host.addEventListener('dblclick', onDbl);

    const apply = () => {
      const c = cursor.get();
      if (c.src === chartId && c.time == null) return;
      applying.current = true;
      if (c.s == null) u.setCursor({ left: -10, top: -10 }, false);
      else u.setCursor({ left: u.valToPos(c.s, 'x'), top: height / 3 }, false);
      applying.current = false;
    };
    apply();
    const unsub = cursor.subscribe(apply);
    return () => {
      unsub();
      ro.disconnect();
      host.removeEventListener('mouseleave', onLeave);
      host.removeEventListener('dblclick', onDbl);
      u.destroy();
      plot.current = null;
    };
  }, [ws, laps, colors, focusKey, id, height, theme, chartId]);

  // Synced zoom.
  useEffect(() => {
    const u = plot.current;
    if (!u) return;
    const xs = ws.ref.s;
    const [min, max] = xRange ?? [xs[0], xs[xs.length - 1]];
    if (u.scales.x.min === min && u.scales.x.max === max) return;
    applying.current = true;
    u.setScale('x', { min, max });
    applying.current = false;
  }, [xRange, ws]);

  return (
    <div className="chart-panel">
      <div className="chart-title">{title} <span>{id === 'speed' ? speedUnit() : unit}</span></div>
      <div ref={el} className="chart-host" />
    </div>
  );
}

function Readout({ ws, laps, labels, colors }: { ws: Workspace; laps: AlignedLap[]; labels: Map<string, string>; colors: Map<string, string> }) {
  const c = useCursor();
  if (c.s == null) return <div className="readout readout--empty">Hover a chart or the map to read values · drag to zoom · double-click to reset</div>;
  return (
    <div className="readout">
      <span className="readout-s">{fmtDist(c.s)}</span>
      {laps.map((l) => {
        const v = sampleAt(l.speed, c.s!);
        const d = sampleAt(l.delta, c.s!);
        return (
          <span key={l.key} className="readout-item">
            <i style={{ background: colors.get(l.key) }} />
            {labels.get(l.key)} <b>{fmtSpeed(v)}</b> {speedUnit()}{l.key !== ws.refKey && <em className={d > 0 ? 'neg' : 'pos'}>{fmtDelta(d, 2)}</em>}
          </span>
        );
      })}
    </div>
  );
}

function Playback({ ws }: { ws: Workspace }) {
  const [playing, setPlaying] = useState(false);
  const [rate, setRate] = useState(1);
  const raf = useRef(0);
  const tRef = useRef(0);
  const total = ws.refLap.time;

  useEffect(() => {
    if (!playing) return;
    let last = performance.now();
    const c = cursor.get();
    tRef.current = c.time ?? (c.s != null ? sampleAt(ws.ref.t, c.s) : 0);
    if (tRef.current >= total - 0.05) tRef.current = 0;
    const step = (now: number) => {
      tRef.current += ((now - last) / 1000) * rate;
      last = now;
      if (tRef.current >= total) {
        tRef.current = total;
        cursor.set({ s: distanceAtTime(ws.ref, total), time: total, src: 'play' });
        setPlaying(false);
        return;
      }
      cursor.set({ s: distanceAtTime(ws.ref, tRef.current), time: tRef.current, src: 'play' });
      raf.current = requestAnimationFrame(step);
    };
    raf.current = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf.current);
  }, [playing, rate, ws, total]);

  return (
    <div className="playback">
      <button type="button" className="btn btn--small btn--accent" onClick={() => setPlaying((p) => !p)} aria-label={playing ? 'Pause' : 'Play'}>
        {playing ? '❚❚ Pause' : '▶ Play'}
      </button>
      <div className="seg" role="group" aria-label="Playback speed">
        {[1, 2, 4].map((r) => (
          <button key={r} type="button" className={rate === r ? 'on' : ''} onClick={() => setRate(r)}>{r}×</button>
        ))}
      </div>
      <button type="button" className="btn btn--small" onClick={() => { setPlaying(false); cursor.clear(); }}>Reset</button>
    </div>
  );
}

export function TelemetryCharts({ ws, laps, colors, labels, focusKey, hasG, theme }: Props) {
  // Zoom is kept per reference lap; changing the reference resets it.
  const [zoom, setZoom] = useState<{ ref: string; range: [number, number] } | null>(null);
  const xRange = zoom && zoom.ref === ws.refKey ? zoom.range : null;
  const setXRange = useCallback(
    (r: [number, number] | null) => setZoom(r ? { ref: ws.refKey, range: r } : null),
    [ws.refKey],
  );
  const aligned = useMemo(() => {
    const out: AlignedLap[] = [];
    for (const l of laps) {
      const a = ws.aligned.get(l.key);
      if (a) out.push(a);
    }
    return out;
  }, [ws, laps]);
  const panels = PANELS.filter((p) => {
    if (p.id === 'gLong') return hasG && aligned.some((a) => a.gLong);
    if (p.id === 'gLat') return hasG && aligned.some((a) => a.gLat);
    return true;
  });

  return (
    <section className="card charts">
      <header className="card-head">
        <h2>Telemetry vs distance</h2>
        <Playback ws={ws} />
      </header>
      <Readout ws={ws} laps={aligned} labels={labels} colors={colors} />
      {panels.map((p) => (
        <Panel key={p.id} {...p} ws={ws} laps={aligned} colors={colors} focusKey={focusKey} theme={theme} xRange={xRange} onZoom={setXRange} />
      ))}
    </section>
  );
}
