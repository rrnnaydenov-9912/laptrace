import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AICoachPanel } from './components/AICoachPanel';
import { CoachPanel } from './components/CoachPanel';
import { CornerExplainer, type ExplainRequest } from './components/CornerExplainer';
import { DriveView } from './components/DriveView';
import { GoalCard } from './components/GoalCard';
import { OpportunitiesPanel } from './components/OpportunitiesPanel';
import { VideoPanel } from './components/VideoPanel';
import { CornerTable } from './components/CornerTable';
import { GGDiagram } from './components/GGDiagram';
import { DropZone, ReportCard, type ImportOutcome } from './components/ImportPanel';
import { LapTable, type LapGroup } from './components/LapTable';
import { Library } from './components/Library';
import { SessionHeader } from './components/SessionHeader';
import { TelemetryCharts } from './components/TelemetryCharts';
import { TopBar } from './components/TopBar';
import { TrackMap } from './components/TrackMap';
import { analyzeSession, summarize } from './lib/analysis';
import { coachLap, coachReference, consistency, type LapCornerStats } from './lib/coach';
import { buildFacts } from './lib/aicoach';
import { carLapStats, carSummary, stint as stintOf } from './lib/car';
import { CarPanel } from './components/CarPanel';
import { StintChart } from './components/StintChart';
import { isDrive } from './lib/drive';
import { fmtDate, LAP_PALETTE, setSpeedUnit, type SpeedUnit } from './lib/format';
import { bestConsecutive, evaluateGoal, opportunities, outlierKeys, suggestGoal, targetTime, type Goal } from './lib/insights';
import {
  clearGoal, deleteSession, deleteUserTrack, listSummaries, listUserTracks, loadGoal, loadSession, saveGoal, saveSession, saveSummary, saveUserTrack,
} from './lib/storage';
import { BUILTIN_TRACKS, gateFromPoints, makeUserTrack } from './lib/tracks';
import type { LapData, LatLon, SessionSummary, TrackDef } from './lib/types';
import { buildWorkspace } from './lib/workspace';
import { cursor } from './state/cursor';
import { importFile, type LoadedSession } from './state/sessions';

const MAX_SELECTED = 8;
type Theme = 'light' | 'dark';

function initialTheme(): Theme {
  try {
    const t = localStorage.getItem('laptrace-theme');
    if (t === 'light' || t === 'dark') return t;
  } catch { /* storage unavailable */ }
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function initialUnits(): SpeedUnit {
  let u: SpeedUnit = 'kmh';
  try { if (localStorage.getItem('laptrace-units') === 'mph') u = 'mph'; } catch { /* storage unavailable */ }
  setSpeedUnit(u);
  return u;
}

/** Timed laps of a session. */
const timedLaps = (s: LoadedSession) => s.a.laps.filter((l) => l.kind === 'timed');

/** Write the lap times of a session as a CSV the user can open in a spreadsheet. */
function exportLapsCsv(s: LoadedSession, excluded: Set<string>) {
  const rows = [['Lap', 'Time (s)', 'Distance (m)', 'Top speed (km/h)', 'Excluded']];
  for (const l of timedLaps(s)) rows.push([l.label, l.time.toFixed(3), l.length.toFixed(0), l.maxSpeed.toFixed(1), excluded.has(l.key) ? 'yes' : '']);
  const csv = rows.map((r) => r.map((c) => (/[",]/.test(c) ? `"${c.replace(/"/g, '""')}"` : c)).join(',')).join('\n');
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = `${s.rec.name.replace(/[^\w.-]+/g, '_')}-laps.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** Default lap selection for a fresh session: the best lap, else the longest run. */
function defaultLap(s: LoadedSession): LapData | null {
  const { a } = s;
  if (a.bestLapIndex != null) return a.laps[a.bestLapIndex];
  return [...a.laps].sort((x, y) => y.length - x.length)[0] ?? null;
}

export default function App() {
  const [theme, setTheme] = useState<Theme>(initialTheme);
  const [units, setUnits] = useState<SpeedUnit>(initialUnits);
  const [excluded, setExcluded] = useState<Set<string>>(new Set());
  const [savedGoal, setSavedGoal] = useState<Goal | null>(null);
  const [explain, setExplain] = useState<ExplainRequest | null>(null);
  const onExplain = useCallback((corner: number, vsKey: string | null) => {
    setExplain((p) => ({ corner, vsKey, n: (p?.n ?? 0) + 1 }));
    requestAnimationFrame(() => document.getElementById('corner-explainer')?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  }, []);
  const [summaries, setSummaries] = useState<SessionSummary[]>([]);
  const [userTracks, setUserTracks] = useState<TrackDef[]>([]);
  const [current, setCurrent] = useState<LoadedSession | null>(null);
  const [compared, setCompared] = useState<LoadedSession[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [refKey, setRefKey] = useState<string | null>(null);
  const [focusKey, setFocusKey] = useState<string | null>(null);
  const [outcomes, setOutcomes] = useState<ImportOutcome[]>([]);
  const [busy, setBusy] = useState(false);
  const [showImport, setShowImport] = useState(false);
  const [libOpen, setLibOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const fileInputClick = useRef<() => void>(() => document.getElementById('file-input')?.click());

  const tracks = useMemo(() => [...BUILTIN_TRACKS, ...userTracks], [userTracks]);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem('laptrace-theme', theme); } catch { /* ignore */ }
  }, [theme]);

  useEffect(() => {
    setSpeedUnit(units);
    try { localStorage.setItem('laptrace-units', units); } catch { /* ignore */ }
  }, [units]);

  useEffect(() => {
    Promise.all([listSummaries(), listUserTracks()])
      .then(([s, t]) => { setSummaries(s); setUserTracks(t); })
      .catch(() => { /* IndexedDB unavailable: app still works for this visit */ })
      .finally(() => setLoading(false));
  }, []);

  const openLoaded = useCallback((s: LoadedSession) => {
    const lap = defaultLap(s);
    setCurrent(s);
    setCompared([]);
    setSelected(lap ? [lap.key] : []);
    setRefKey(lap?.key ?? null);
    setFocusKey(lap?.key ?? null);
    setExcluded(outlierKeys(timedLaps(s)));
    setShowImport(false);
    setLibOpen(false);
    cursor.clear();
  }, []);

  const openSession = useCallback(async (id: string) => {
    const rec = await loadSession(id);
    if (!rec) return;
    openLoaded({ rec, a: analyzeSession(rec, tracks) });
  }, [openLoaded, tracks]);

  const handleFiles = useCallback(async (files: File[]) => {
    setBusy(true);
    setShowImport(true);
    const results: ImportOutcome[] = [];
    let last: LoadedSession | null = null;
    const newSummaries: SessionSummary[] = [];
    for (const f of files) {
      const r = await importFile(f, tracks);
      results.push(r.outcome);
      if (r.loaded) last = r.loaded;
      if (r.summary) newSummaries.push(r.summary);
    }
    setSummaries((s) => [...s, ...newSummaries]);
    setOutcomes((o) => [...results, ...o].slice(0, 6));
    setBusy(false);
    if (last) openLoaded(last);
  }, [openLoaded, tracks]);

  const loadSample = useCallback(async () => {
    setBusy(true);
    try {
      const res = await fetch(`${import.meta.env.BASE_URL}sample-phone-session.csv`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const blob = await res.blob();
      await handleFiles([new File([blob], 'sample-phone-session.csv', { type: 'text/csv' })]);
    } catch (e) {
      setOutcomes((o) => [{ fileName: 'sample-phone-session.csv', ok: false, error: `Could not load the sample: ${e instanceof Error ? e.message : e}` }, ...o]);
      setBusy(false);
    }
  }, [handleFiles]);

  // Accept files dropped anywhere on the window.
  useEffect(() => {
    const over = (e: DragEvent) => { if (e.dataTransfer?.types.includes('Files')) e.preventDefault(); };
    const drop = (e: DragEvent) => {
      if (!e.dataTransfer?.files.length) return;
      e.preventDefault();
      void handleFiles(Array.from(e.dataTransfer.files));
    };
    window.addEventListener('dragover', over);
    window.addEventListener('drop', drop);
    return () => { window.removeEventListener('dragover', over); window.removeEventListener('drop', drop); };
  }, [handleFiles]);

  const rename = useCallback(async (id: string, name: string) => {
    const rec = current?.rec.id === id ? current.rec : await loadSession(id);
    if (!rec) return;
    const updated = { ...rec, name };
    const sum = summaries.find((s) => s.id === id);
    if (sum) await saveSession(updated, { ...sum, name });
    setSummaries((ss) => ss.map((s) => (s.id === id ? { ...s, name } : s)));
    if (current?.rec.id === id) setCurrent({ rec: updated, a: current.a });
  }, [current, summaries]);

  const remove = useCallback(async (id: string) => {
    await deleteSession(id);
    setSummaries((ss) => ss.filter((s) => s.id !== id));
    if (current?.rec.id === id) { setCurrent(null); setSelected([]); setRefKey(null); setFocusKey(null); }
    setCompared((c) => c.filter((x) => x.rec.id !== id));
  }, [current]);

  const trackId = current?.a.track?.id ?? null;
  useEffect(() => {
    setSavedGoal(null);
    if (!trackId) return;
    let live = true;
    loadGoal(trackId).then((g) => { if (live) setSavedGoal(g ?? null); }).catch(() => {});
    return () => { live = false; };
  }, [trackId]);

  const favorite = useCallback(async (id: string, fav: boolean) => {
    const sum = summaries.find((s) => s.id === id);
    if (!sum) return;
    const next = { ...sum, favorite: fav };
    setSummaries((ss) => ss.map((s) => (s.id === id ? next : s)));
    await saveSummary(next).catch(() => {});
  }, [summaries]);

  // Re-analyse the current session after its timing line changes.
  const reanalyse = useCallback(async (s: LoadedSession, nextTracks: TrackDef[]) => {
    const a = analyzeSession(s.rec, nextTracks);
    const summary = summarize(s.rec, a);
    await saveSession(s.rec, summary);
    setSummaries((ss) => ss.map((x) => (x.id === summary.id ? summary : x)));
    openLoaded({ rec: s.rec, a });
  }, [openLoaded]);

  const defineGate = useCallback(async (p1: LatLon, p2: LatLon) => {
    if (!current) return;
    const gate = gateFromPoints(p1, p2, current.rec.channels);
    const rec = { ...current.rec, customGate: gate };
    let next = userTracks;
    if (!current.a.track) {
      const t = makeUserTrack(`My track near ${current.a.center.lat.toFixed(3)}, ${current.a.center.lon.toFixed(3)}`, current.a.center, gate);
      await saveUserTrack(t);
      next = [...userTracks, t];
      setUserTracks(next);
    }
    await reanalyse({ rec, a: current.a }, [...BUILTIN_TRACKS, ...next]);
  }, [current, reanalyse, userTracks]);

  const resetGate = useCallback(async () => {
    if (!current) return;
    const t = current.a.track;
    let next = userTracks;
    if (t?.userDefined) {
      await deleteUserTrack(t.id);
      next = userTracks.filter((x) => x.id !== t.id);
      setUserTracks(next);
    }
    await reanalyse({ rec: { ...current.rec, customGate: null }, a: current.a }, [...BUILTIN_TRACKS, ...next]);
  }, [current, reanalyse, userTracks]);

  // Other stored sessions at the same track, available for comparison.
  const comparable = useMemo(() => {
    const tid = current?.a.track?.id;
    if (!tid) return [];
    return summaries.filter((s) => s.trackId === tid && s.id !== current.rec.id && !compared.some((c) => c.rec.id === s.id));
  }, [summaries, current, compared]);

  const addCompare = useCallback(async (id: string) => {
    const rec = await loadSession(id);
    if (!rec) return;
    const s = { rec, a: analyzeSession(rec, tracks) };
    setCompared((c) => [...c, s]);
    const best = s.a.bestLapIndex != null ? s.a.laps[s.a.bestLapIndex].key : null;
    if (best) setSelected((sel) => (sel.length < MAX_SELECTED && !sel.includes(best) ? [...sel, best] : sel));
  }, [tracks]);

  const removeCompare = useCallback((sessionId: string) => {
    setCompared((c) => c.filter((x) => x.rec.id !== sessionId));
    const prefix = `${sessionId}:`;
    setSelected((sel) => sel.filter((k) => !k.startsWith(prefix)));
    setRefKey((r) => (r?.startsWith(prefix) ? null : r));
    setFocusKey((f) => (f?.startsWith(prefix) ? null : f));
  }, []);

  // ---- derived view state -------------------------------------------------
  const allSessions = useMemo(() => (current ? [current, ...compared] : []), [current, compared]);
  const lapIndex = useMemo(() => {
    const m = new Map<string, { lap: LapData; s: LoadedSession }>();
    for (const s of allSessions) for (const lap of s.a.laps) m.set(lap.key, { lap, s });
    return m;
  }, [allSessions]);

  const labels = useMemo(() => {
    const m = new Map<string, string>();
    for (const s of allSessions) {
      const own = s === current;
      const tag = own ? '' : `${fmtDate(s.rec.date).split(',')[0] || s.rec.name} · `;
      for (const lap of s.a.laps) m.set(lap.key, `${tag}${lap.label}`);
    }
    return m;
  }, [allSessions, current]);

  const fallback = current ? defaultLap(current) : null;
  const refLap = (refKey && lapIndex.get(refKey)?.lap) || fallback;
  const focusLap = (focusKey && lapIndex.get(focusKey)?.lap) || refLap;

  const colors = useMemo(() => {
    const m = new Map<string, string>();
    selected.forEach((k, i) => m.set(k, LAP_PALETTE[i % LAP_PALETTE.length]));
    if (focusLap && !m.has(focusLap.key)) m.set(focusLap.key, '#8a8f98');
    return m;
  }, [selected, focusLap]);

  const shownLaps = useMemo(() => {
    const keys = [...selected];
    if (focusLap && !keys.includes(focusLap.key)) keys.push(focusLap.key);
    return keys.map((k) => lapIndex.get(k)?.lap).filter((l): l is LapData => !!l && l.t.length > 1);
  }, [selected, focusLap, lapIndex]);

  const ws = useMemo(() => {
    if (!refLap || refLap.t.length < 2) return null;
    const timed = current ? current.a.laps.filter((l) => l.kind === 'timed') : [];
    return buildWorkspace(refLap, [...shownLaps, ...timed]);
  }, [refLap, shownLaps, current]);

  const lapStats = useCallback((lap: LapData): LapCornerStats | null => {
    const st = ws?.stats.get(lap.key);
    return st ? { key: lap.key, label: labels.get(lap.key) ?? lap.label, time: lap.time, stats: st } : null;
  }, [ws, labels]);

  const cons = useMemo(() => {
    if (!current || !ws) return null;
    const ls = timedLaps(current).filter((l) => !excluded.has(l.key)).map(lapStats).filter((x): x is LapCornerStats => !!x);
    return ls.length ? consistency(ls) : null;
  }, [current, ws, lapStats, excluded]);

  // ---- insights: where the time is, target lap, goals, AI facts -----------
  const includedTimed = useMemo(() => (current ? timedLaps(current).filter((l) => !excluded.has(l.key)) : []), [current, excluded]);
  const includedStats = useMemo(() => includedTimed.map(lapStats).filter((x): x is LapCornerStats => !!x), [includedTimed, lapStats]);
  const opps = useMemo(() => {
    const ref = refLap ? lapStats(refLap) : null;
    return ref ? opportunities(ref, includedStats) : [];
  }, [refLap, lapStats, includedStats]);
  const target = useMemo(() => (refLap && opps.length ? targetTime(refLap.time, opps) : null), [refLap, opps]);
  const bestThree = useMemo(() => bestConsecutive(includedTimed), [includedTimed]);
  const goalProgress = useMemo(() => (savedGoal && ws ? evaluateGoal(savedGoal, ws, includedStats, cons?.lapTimeSd ?? null) : null), [savedGoal, ws, includedStats, cons]);
  const nextGoal = useMemo(() => {
    if (!ws || !current?.a.track) return null;
    return suggestGoal({
      ws, opps, lapTimeSd: cons?.lapTimeSd ?? null, lapCount: includedTimed.length,
      trackId: current.a.track.id, trackName: current.a.track.name, sessionId: current.rec.id,
    });
  }, [ws, opps, cons, includedTimed, current]);
  const car = useMemo(() => {
    if (!refLap?.car) return null;
    const lbl = (l: LapData) => labels.get(l.key) ?? l.label;
    const laps = includedTimed.map((l) => carLapStats(l, lbl(l))).filter((x) => x != null);
    return carSummary(carLapStats(refLap, lbl(refLap)), laps);
  }, [refLap, includedTimed, labels]);
  const stintData = useMemo(() => (car ? stintOf(car.laps) : null), [car]);
  const facts = useMemo(() => {
    if (!current || !cons || !refLap) return null;
    return buildFacts({
      track: current.a.track?.name ?? null,
      date: current.rec.date,
      vehicle: current.rec.meta.Vehicle ?? null,
      timedLaps: timedLaps(current).map((l) => ({ label: l.label, time: l.time, excluded: excluded.has(l.key) })),
      reference: { label: labels.get(refLap.key) ?? refLap.label, time: refLap.time },
      target, bestThree, opps, cons,
      goal: savedGoal, goalProgress, nextGoal,
      lowRateGps: current.a.lowRateGps,
      car,
    });
    // units: facts carry speeds in the display unit
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [current, cons, refLap, labels, target, bestThree, opps, savedGoal, goalProgress, nextGoal, excluded, units, car]);

  const tips = useMemo(() => {
    if (!ws || !focusLap || !refLap) return [];
    const ref = lapStats(refLap);
    if (!ref) return [];
    if (focusLap.key === refLap.key) {
      const others = shownLaps.concat(current ? current.a.laps.filter((l) => l.kind === 'timed') : [])
        .filter((l, i, arr) => l.key !== refLap.key && arr.findIndex((x) => x.key === l.key) === i)
        .map(lapStats).filter((x): x is LapCornerStats => !!x);
      return coachReference(ref, others);
    }
    const f = lapStats(focusLap);
    return f ? coachLap(f, ref) : [];
  }, [ws, focusLap, refLap, lapStats, shownLaps, current]);

  const toggle = useCallback((key: string) => {
    setSelected((sel) => (sel.includes(key) ? sel.filter((k) => k !== key) : sel.length < MAX_SELECTED ? [...sel, key] : sel));
  }, []);

  // Keyboard: ← / → step through laps, r makes the focused lap the reference, t switches theme.
  const keyState = useRef({ current, focusLap, refLap });
  keyState.current = { current, focusLap, refLap };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const tgt = e.target as HTMLElement | null;
      if (tgt && (tgt.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(tgt.tagName))) return;
      const { current: cur, focusLap: f } = keyState.current;
      if (e.key === 't') { setTheme((t) => (t === 'dark' ? 'light' : 'dark')); return; }
      if (!cur || !f) return;
      if (e.key === 'r') { setRefKey(f.key); return; }
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        const laps = cur.a.laps;
        const i = laps.findIndex((l) => l.key === f.key);
        if (i < 0) return;
        const j = i + (e.key === 'ArrowRight' ? 1 : -1);
        if (j < 0 || j >= laps.length) return;
        e.preventDefault();
        setFocusKey(laps[j].key);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const toggleExcluded = useCallback((key: string) => {
    setExcluded((ex) => { const n = new Set(ex); if (n.has(key)) n.delete(key); else n.add(key); return n; });
  }, []);

  const groups: LapGroup[] = allSessions.map((s) => ({
    title: s === current ? `${s.rec.name} (this session)` : `${s.rec.name} · ${fmtDate(s.rec.date)}`,
    analysis: s.a,
    removable: s !== current,
  }));

  const overlays = shownLaps.filter((l) => l.key !== focusLap?.key);
  const focusLabel = focusLap ? labels.get(focusLap.key) ?? focusLap.label : '';
  const focusSessionLowRate = focusLap ? lapIndex.get(focusLap.key)?.s.a.lowRateGps ?? false : false;

  const importView = showImport || !current;
  const drive = current ? isDrive(current.rec, current.a) : false;
  const videoStart = current?.rec.meta['Video Start UTC'] ? Date.parse(current.rec.meta['Video Start UTC']) / 1000 : NaN;

  return (
    <div className={`app ${libOpen ? 'lib-open' : ''}`}>
      <TopBar
        theme={theme}
        onTheme={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}
        onImport={() => { setShowImport(true); setLibOpen(false); setTimeout(() => fileInputClick.current(), 0); }}
        onLibrary={() => setLibOpen((o) => !o)}
        libraryOpen={libOpen}
        units={units}
        onUnits={() => setUnits((u) => (u === 'kmh' ? 'mph' : 'kmh'))}
      />
      <div className="layout">
        <aside className="sidebar" aria-label="Session library">
          <Library
            summaries={summaries}
            currentId={current?.rec.id ?? null}
            onOpen={(id) => void openSession(id)}
            onRename={(id, n) => void rename(id, n)}
            onDelete={(id) => void remove(id)}
            onFavorite={(id, f) => void favorite(id, f)}
            onImport={() => { setShowImport(true); setLibOpen(false); }}
          />
        </aside>
        {libOpen && <div className="scrim" onClick={() => setLibOpen(false)} />}
        <main className="main">
          {importView && (
            <section className="import-view">
              {current && (
                <button type="button" className="link back" onClick={() => setShowImport(false)}>← Back to {current.rec.name}</button>
              )}
              <DropZone busy={busy} onFiles={(f) => void handleFiles(f)} onSample={() => void loadSample()} compact={!!current} />
              {outcomes.length > 0 && (
                <div className="reports">
                  {outcomes.map((o, i) => (
                    <ReportCard
                      key={`${o.fileName}-${i}`}
                      o={o}
                      onOpen={o.sessionId ? () => void openSession(o.sessionId!) : undefined}
                      onDismiss={() => setOutcomes((all) => all.filter((x) => x !== o))}
                    />
                  ))}
                </div>
              )}
              {!current && !loading && summaries.length > 0 && (
                <p className="hint center">Or pick a saved session from the library.</p>
              )}
            </section>
          )}
          {current && !showImport && drive && (
            <>
              <SessionHeader rec={current.rec} a={current.a} />
              <DriveView key={`${current.rec.id}-${units}`} rec={current.rec} a={current.a} theme={theme} />
            </>
          )}
          {current && !showImport && !drive && (
            <>
              <SessionHeader rec={current.rec} a={current.a} />
              <div className="grid-top">
                <section className="card map-card">
                  <TrackMap
                    ws={ws}
                    focus={focusLap}
                    overlays={overlays}
                    colors={colors}
                    startFinish={current.a.startFinish}
                    sectorGates={current.a.sectorGates}
                    center={current.a.center}
                    fitKey={current.rec.id}
                    canDefineGate
                    onDefineGate={(a, b) => void defineGate(a, b)}
                    onResetGate={current.rec.customGate || current.a.track?.userDefined ? () => void resetGate() : null}
                  />
                </section>
                <div className="laps-col">
                  <LapTable
                    groups={groups}
                    selected={selected}
                    colors={colors}
                    refKey={refLap?.key ?? null}
                    focusKey={focusLap?.key ?? null}
                    maxSelected={MAX_SELECTED}
                    onToggle={toggle}
                    onRef={(k) => setRefKey(k)}
                    onFocus={(k) => setFocusKey(k)}
                    onRemoveGroup={removeCompare}
                  />
                  {timedLaps(current).length > 1 && (
                    <div className="lap-filter">
                      <div className="lap-filter-head">
                        <span>Laps counted in the stats</span>
                        <button type="button" className="link" onClick={() => exportLapsCsv(current, excluded)}>Export lap times</button>
                      </div>
                      <div className="chips">
                        {timedLaps(current).map((l) => (
                          <button
                            key={l.key}
                            type="button"
                            className={`chip chip-btn ${excluded.has(l.key) ? 'chip--muted' : ''}`}
                            aria-pressed={!excluded.has(l.key)}
                            title={excluded.has(l.key) ? 'Not counted. Click to include.' : 'Counted. Click to leave out (e.g. traffic or a spin).'}
                            onClick={() => toggleExcluded(l.key)}
                          >
                            {l.label}
                          </button>
                        ))}
                      </div>
                      <p className="hint">Unusually slow laps are left out automatically. Shortcuts: ← → change lap, r sets reference, t switches theme.</p>
                    </div>
                  )}
                  {comparable.length > 0 && (
                    <div className="compare">
                      <label htmlFor="compare-select">Compare with another session at {current.a.track?.name}</label>
                      <select
                        id="compare-select"
                        value=""
                        onChange={(e) => { if (e.target.value) void addCompare(e.target.value); }}
                      >
                        <option value="">Choose a session…</option>
                        {comparable.map((s) => (
                          <option key={s.id} value={s.id}>{s.name} · {fmtDate(s.date)}</option>
                        ))}
                      </select>
                    </div>
                  )}
                </div>
              </div>
              {ws && refLap && (
                <OpportunitiesPanel
                  ws={ws}
                  refLabel={labels.get(refLap.key) ?? refLap.label}
                  refTime={refLap.time}
                  opps={opps}
                  target={target}
                  bestThree={bestThree}
                  lowRateGps={current.a.lowRateGps}
                  onExplain={onExplain}
                />
              )}
              {ws && (
                <TelemetryCharts
                  key={units}
                  ws={ws}
                  laps={shownLaps}
                  colors={colors}
                  labels={labels}
                  focusKey={focusLap?.key ?? null}
                  hasG={current.a.hasG}
                  theme={theme}
                />
              )}
              {ws && focusLap && (
                <div className="grid-bottom">
                  {current.a.hasG && <GGDiagram lap={focusLap} ws={ws} theme={theme} />}
                  <CornerTable ws={ws} focusKey={focusLap.key} focusLabel={focusLabel} cons={cons} />
                  <CoachPanel
                    ws={ws}
                    tips={tips}
                    isRef={focusLap.key === ws.refKey}
                    focusLabel={focusLabel}
                    cons={cons}
                    lowRateGps={focusSessionLowRate}
                    focusKey={focusLap.key}
                    labels={labels}
                    onExplain={onExplain}
                  />
                </div>
              )}
              {ws && focusLap && (
                <div className="grid-insights">
                  <CornerExplainer ws={ws} focusKey={focusLap.key} focusLabel={focusLabel} labels={labels} request={explain} />
                  {car && <CarPanel summary={car} refLabel={labels.get(car.ref.key) ?? car.ref.label} />}
                  {stintData && <StintChart stint={stintData} />}
                  {current.a.track && (
                    <GoalCard
                      trackName={current.a.track.name}
                      saved={savedGoal}
                      progress={goalProgress}
                      next={nextGoal}
                      onSave={(g) => { setSavedGoal(g); void saveGoal(g).catch(() => {}); }}
                      onClear={() => { const id = current.a.track!.id; setSavedGoal(null); void clearGoal(id).catch(() => {}); }}
                    />
                  )}
                </div>
              )}
              {facts && <AICoachPanel key={`${current.rec.id}-${units}`} facts={facts} fallback={tips.map((t) => t.text)} />}
              {ws && focusLap && (
                <VideoPanel ws={ws} lap={focusLap} videoStartUtc={Number.isFinite(videoStart) ? videoStart : null} />
              )}
            </>
          )}
        </main>
      </div>
    </div>
  );
}
