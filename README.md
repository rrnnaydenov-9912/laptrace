# Laptrace

Personal track-day telemetry: an iPhone recorder plus an analysis web app.

| Folder | What |
|---|---|
| `recorder-ios/` | **Laptrace Logger**: a native SwiftUI iPhone app. It records phone GPS and motion data, shows live lap times, and exports CSV. |
| `studio-web/` | **Laptrace Studio**: an analysis web app written from scratch. It imports CSV and shows laps, map, traces, comparisons, corners and coaching. |
| `shared/` | The data contract: `CSV-FORMAT.md`, `tracks.json` (timing gates) and a sample session. |

## Data contract (summary)
CSV with metadata rows, a blank line, then this header:
```
Time,Lap,Latitude,Longitude,Altitude (m),Speed (km/h),Heading (deg),Longitudinal (g),Lateral (g),Vertical (g),GPS Accuracy (m),GPS Fix
```
- `Time` is Unix seconds.
- `Lap`: `0` marks the out/in lap; `1..n` are timed laps.
- `Longitudinal (g)`: positive = accelerating.
- `Lateral (g)`: positive = turning right.
- `GPS Fix`: `1` for a row at a real GPS fix, `0` for an interpolated row.
