// Leaflet track map: speed-coloured focus lap, overlay laps, gates, corners and
// a cursor linked to the charts. Imperative Leaflet inside React effects.

import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { cursor } from '../state/cursor';
import { sampleAt } from '../lib/alignment';
import { nearestS, positionAtTime, type Workspace } from '../lib/workspace';
import { fmtSpeed, fmtSpeedU, speedColor } from '../lib/format';
import { DRIVE_ACCEL, DRIVE_BRAKE, driveStates } from '../lib/insights';
import type { Gate, LapData, LatLon } from '../lib/types';

interface Props {
  ws: Workspace | null;
  focus: LapData | null;
  overlays: LapData[];
  colors: Map<string, string>;
  startFinish: Gate | null;
  sectorGates: Gate[];
  center: LatLon;
  /** Fit the view when this changes (e.g. session id). */
  fitKey: string;
  canDefineGate: boolean;
  onDefineGate: (a: LatLon, b: LatLon) => void;
  onResetGate: (() => void) | null;
}

const OSM = 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';
const ESRI = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

const PEDAL_COLORS = ['#7d8ca3', '#e5484d', '#30a46c'];

/** Split the lap into runs of braking / accelerating / coasting. */
function pedalSegments(lap: LapData): { color: string; pts: L.LatLngTuple[] }[] {
  const st = driveStates(lap);
  const out: { color: string; pts: L.LatLngTuple[] }[] = [];
  let cur: L.LatLngTuple[] = [];
  let state = -1;
  for (let i = 0; i < lap.lat.length; i++) {
    const p: L.LatLngTuple = [lap.lat[i], lap.lon[i]];
    if (st[i] !== state) {
      if (cur.length) { cur.push(p); out.push({ color: PEDAL_COLORS[state], pts: cur }); }
      cur = [p];
      state = st[i];
    } else cur.push(p);
  }
  if (cur.length > 1) out.push({ color: PEDAL_COLORS[state], pts: cur });
  return out;
}

function speedSegments(lap: LapData, buckets = 28): { color: string; pts: L.LatLngTuple[] }[] {
  const out: { color: string; pts: L.LatLngTuple[] }[] = [];
  const min = lap.minSpeed;
  const max = lap.maxSpeed;
  let curBucket = -1;
  let cur: L.LatLngTuple[] = [];
  for (let i = 0; i < lap.lat.length; i++) {
    const t = max > min ? (lap.speed[i] - min) / (max - min) : 0.5;
    const b = Math.min(buckets - 1, Math.max(0, Math.floor(t * buckets)));
    const p: L.LatLngTuple = [lap.lat[i], lap.lon[i]];
    if (b !== curBucket) {
      if (cur.length) { cur.push(p); out.push({ color: speedColor(min + ((curBucket + 0.5) / buckets) * (max - min), min, max), pts: cur }); }
      cur = [p];
      curBucket = b;
    } else cur.push(p);
  }
  if (cur.length > 1) out.push({ color: speedColor(min + ((curBucket + 0.5) / buckets) * (max - min), min, max), pts: cur });
  return out;
}

export function TrackMap(props: Props) {
  const { ws, focus, overlays, colors, startFinish, sectorGates, center, fitKey, canDefineGate, onDefineGate, onResetGate } = props;
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const groups = useRef<{ lines: L.LayerGroup; gates: L.LayerGroup; corners: L.LayerGroup; cursor: L.LayerGroup; draft: L.LayerGroup } | null>(null);
  const wsRef = useRef(ws);
  const lapsRef = useRef<{ focus: LapData | null; overlays: LapData[]; colors: Map<string, string> }>({ focus, overlays, colors });
  const [drawing, setDrawing] = useState(false);
  const [mode, setMode] = useState<'speed' | 'pedal'>('speed');
  const drawingRef = useRef(false);
  const draftPts = useRef<LatLon[]>([]);
  const defineRef = useRef(onDefineGate);

  wsRef.current = ws;
  lapsRef.current = { focus, overlays, colors };
  defineRef.current = onDefineGate;
  drawingRef.current = drawing;

  // Create the map once.
  useEffect(() => {
    if (!el.current) return;
    const m = L.map(el.current, { preferCanvas: true, zoomControl: true, attributionControl: true });
    const osm = L.tileLayer(OSM, { maxZoom: 20, maxNativeZoom: 19, className: 'osm-tiles', attribution: '© OpenStreetMap contributors' });
    const sat = L.tileLayer(ESRI, { maxZoom: 20, maxNativeZoom: 19, attribution: 'Imagery © Esri' });
    osm.addTo(m);
    L.control.layers({ Map: osm, Satellite: sat }, undefined, { position: 'topright' }).addTo(m);
    L.control.scale({ imperial: false, position: 'bottomleft' }).addTo(m);
    const g = {
      lines: L.layerGroup().addTo(m),
      gates: L.layerGroup().addTo(m),
      corners: L.layerGroup().addTo(m),
      cursor: L.layerGroup().addTo(m),
      draft: L.layerGroup().addTo(m),
    };
    groups.current = g;
    map.current = m;

    m.on('mousemove', (e: L.LeafletMouseEvent) => {
      if (drawingRef.current || !wsRef.current) return;
      const s = nearestS(wsRef.current, e.latlng.lat, e.latlng.lng, 40);
      if (s != null) cursor.set({ s, time: null, src: 'map' });
    });
    m.on('click', (e: L.LeafletMouseEvent) => {
      if (!drawingRef.current) return;
      const p = { lat: e.latlng.lat, lon: e.latlng.lng };
      draftPts.current.push(p);
      g.draft.clearLayers();
      for (const q of draftPts.current) L.circleMarker([q.lat, q.lon], { radius: 5, color: '#fff', fillColor: '#ff2d2d', fillOpacity: 1, weight: 2 }).addTo(g.draft);
      if (draftPts.current.length === 2) {
        const [a, b] = draftPts.current;
        draftPts.current = [];
        g.draft.clearLayers();
        setDrawing(false);
        defineRef.current(a, b);
      }
    });

    const ro = new ResizeObserver(() => m.invalidateSize());
    ro.observe(el.current);
    return () => { ro.disconnect(); m.remove(); map.current = null; groups.current = null; };
  }, []);

  // Fit to the session.
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    const lap = lapsRef.current.focus;
    if (lap && lap.lat.length > 1) {
      const b = L.latLngBounds(Array.from(lap.lat, (la, i) => [la, lap.lon[i]] as L.LatLngTuple));
      m.fitBounds(b, { padding: [24, 24] });
    } else m.setView([center.lat, center.lon], 15);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fitKey]);

  // Lines.
  useEffect(() => {
    const g = groups.current;
    if (!g) return;
    g.lines.clearLayers();
    for (const lap of overlays) {
      if (lap.key === focus?.key) continue;
      L.polyline(Array.from(lap.lat, (la, i) => [la, lap.lon[i]] as L.LatLngTuple), {
        color: colors.get(lap.key) ?? '#888', weight: 2, opacity: 0.85, interactive: false,
      }).addTo(g.lines);
    }
    if (focus) {
      // Dark casing makes the coloured line readable on both base layers.
      L.polyline(Array.from(focus.lat, (la, i) => [la, focus.lon[i]] as L.LatLngTuple), {
        color: '#0b0d12', weight: 7, opacity: 0.55, interactive: false,
      }).addTo(g.lines);
      for (const seg of mode === 'pedal' ? pedalSegments(focus) : speedSegments(focus)) {
        L.polyline(seg.pts, { color: seg.color, weight: 4, opacity: 1, interactive: false, lineCap: 'butt' }).addTo(g.lines);
      }
    }
  }, [focus, overlays, colors, mode]);

  // Gates and corners.
  useEffect(() => {
    const g = groups.current;
    if (!g) return;
    g.gates.clearLayers();
    g.corners.clearLayers();
    const gateLine = (gate: Gate, color: string, label: string) => {
      L.polyline([[gate.start.lat, gate.start.lon], [gate.end.lat, gate.end.lon]], { color, weight: 4, dashArray: gate.id === 'sf' ? '4 4' : undefined, interactive: true })
        .bindTooltip(label, { direction: 'top' })
        .addTo(g.gates);
    };
    if (startFinish) gateLine(startFinish, '#ff2d2d', 'Start / finish');
    sectorGates.forEach((gt, i) => gateLine(gt, '#ffb300', `Split ${i + 1}`));
    if (ws) {
      for (const c of ws.corners) {
        const icon = L.divIcon({ className: 'corner-pin', html: `<span>${c.number}</span>`, iconSize: [22, 22], iconAnchor: [11, 11] });
        L.marker([c.apexLat, c.apexLon], { icon, keyboard: false })
          .on('click', () => cursor.set({ s: c.sApex, time: null, src: 'corner' }))
          .bindTooltip(`Corner ${c.number} · ${c.direction === 'R' ? 'right' : 'left'} · ${Math.round(c.angle)}°`, { direction: 'top', offset: [0, -10] })
          .addTo(g.corners);
      }
    }
  }, [startFinish, sectorGates, ws]);

  // Cursor markers (subscribe outside React for smooth hover).
  useEffect(() => {
    const draw = () => {
      const g = groups.current;
      const w = wsRef.current;
      if (!g) return;
      g.cursor.clearLayers();
      const c = cursor.get();
      if (!w || c.s == null) return;
      const { overlays: ov, focus: fo, colors: col } = lapsRef.current;
      const laps = fo && !ov.some((l) => l.key === fo.key) ? [...ov, fo] : ov;
      for (const lap of laps) {
        let pos: [number, number] | null = null;
        if (c.time != null) pos = positionAtTime(lap, c.time);
        else {
          const a = w.aligned.get(lap.key);
          if (a) {
            const la = sampleAt(a.lat, c.s);
            const lo = sampleAt(a.lon, c.s);
            if (Number.isFinite(la) && Number.isFinite(lo)) pos = [la, lo];
          }
        }
        if (!pos) continue;
        L.circleMarker(pos, {
          radius: lap.key === fo?.key ? 7 : 5, color: '#fff', weight: 2,
          fillColor: col.get(lap.key) ?? '#888', fillOpacity: 1, interactive: false,
        }).addTo(g.cursor);
      }
    };
    draw();
    return cursor.subscribe(draw);
  }, [ws, focus, overlays, colors]);

  const startDrawing = () => {
    draftPts.current = [];
    groups.current?.draft.clearLayers();
    setDrawing((d) => !d);
  };

  return (
    <div className="map-wrap">
      <div ref={el} className={`map ${drawing ? 'map--drawing' : ''}`} />
      <div className="map-tools">
        {focus && (
          <button type="button" className="btn btn--small" aria-pressed={mode === 'pedal'} onClick={() => setMode((m) => (m === 'speed' ? 'pedal' : 'speed'))}
            title="Switch the lap colouring between speed and braking/throttle">
            {mode === 'speed' ? 'Colour: speed' : 'Colour: pedals'}
          </button>
        )}
        {canDefineGate && (
          <button type="button" className={`btn btn--small ${drawing ? 'btn--accent' : ''}`} onClick={startDrawing}>
            {drawing ? 'Cancel' : 'Set start/finish'}
          </button>
        )}
        {onResetGate && !drawing && (
          <button type="button" className="btn btn--small" onClick={onResetGate}>Reset start/finish</button>
        )}
      </div>
      {drawing && (
        <div className="map-hint">Click two points on either side of the track to draw the start/finish line.</div>
      )}
      {focus && mode === 'pedal' && (
        <div className="map-legend map-legend--pedal" aria-hidden>
          <span><b style={{ background: PEDAL_COLORS[DRIVE_BRAKE] }} />Braking</span>
          <span><b style={{ background: PEDAL_COLORS[DRIVE_ACCEL] }} />Throttle</span>
          <span><b style={{ background: PEDAL_COLORS[0] }} />Coast</span>
        </div>
      )}
      {focus && mode === 'speed' && (
        <div className="map-legend" aria-hidden>
          <span>{fmtSpeed(focus.minSpeed)}</span>
          <i />
          <span>{fmtSpeedU(focus.maxSpeed)}</span>
        </div>
      )}
    </div>
  );
}
