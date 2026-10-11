# Laptrace Studio

Browser app for analysing track-day lap telemetry from CSV files (for example, the Laptrace iPhone recorder export). Everything runs locally in the browser. Sessions are kept in IndexedDB and are never uploaded.

## Run

```bash
npm install
npm run dev        # http://localhost:5173 (or: --port 5180)
```

Other scripts: `npm test` (Vitest), `npm run build` (type-check + production bundle), `npm run lint` (oxlint).

## What it does

- **Import**: drag-and-drop or pick one or more CSVs. Parsing runs in a Web Worker and produces a validation report (rows, sample rate, columns, warnings). Imported sessions go into a library where you can rename or delete them.
- **Track recognition**: a session is matched against `src/data/tracks.json` using start/finish gates. If no track matches, laps come from the CSV `Lap` column. You can also click twice on the map to draw your own start/finish line, and the app remembers it.
- **Lap table**: sector times with the best sectors highlighted, Vmax, delta to best, and the theoretical best. Out laps and in laps are excluded from the best.
- **Map**: a speed-coloured racing line with a cursor that stays in sync, plus corner markers. You can switch between OSM and satellite tiles.
- **Charts against distance**: speed, longitudinal g, lateral g and time delta. Laps are resampled to 1 m. You can overlay up to 8 laps, including laps from other sessions at the same track. The reference is the best lap by default.
- **G-G diagram**, **corner analysis** (entry, apex and exit speeds and time lost per corner), and a **rule-based coach** that gives the top 3 tips and lap-time consistency (σ).

## Accuracy

Phone GPS is roughly 1 Hz at source, so lap and sector times are approximate (±0.1–0.5 s). The app shows this caveat whenever it detects low-rate GPS.

## Layout

```
src/lib/        parsing, gates, laps, alignment, corners, coach, storage (pure TS, tested)
src/lib/csv/    CSV parser + Web Worker client
src/components/ UI (map, charts, tables, G-G, coach, library, import)
src/state/      cursor sync store, import pipeline
public/         sample session, PWA manifest + service worker
```
