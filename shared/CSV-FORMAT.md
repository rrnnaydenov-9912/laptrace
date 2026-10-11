# Laptrace CSV format

The contract between **Laptrace Logger** (iPhone) and **Laptrace Studio** (web). `sample-phone-session.csv` is a valid example.

```csv
Format,Laptrace Logger CSV
Date UTC,2026-07-03T12:00:00Z
Track,A1 Motor Park (full)
Device,iPhone
G-Force Source,Phone IMU auto-aligned
Lateral Sign,positive = right turn

Time,Lap,Latitude,Longitude,Altitude (m),Speed (km/h),Heading (deg),Longitudinal (g),Lateral (g),Vertical (g),GPS Accuracy (m),GPS Fix
1783065600.0,0,42.6000000,24.3030806,580.0,95.00,0.0,0.000,0.900,1.000,4.0,1
```

## Layout
- **Metadata**: `Key,Value` rows first, then one blank line, then the header row. Rows starting with `#` are comments.
- **Delimiter**: comma. Studio also accepts `;`, tab and `|`.

## Columns
| Column | Required | Meaning |
|---|---|---|
| `Time` | yes | Unix seconds with decimals. Increasing. |
| `Latitude`, `Longitude` | yes | WGS84 decimal degrees. Every row has a position; no blank or `0,0` rows. |
| `Lap` | no | `0` = out/in lap, `1..n` = timed laps. Omitted when no start/finish was crossed; Studio then finds laps itself. |
| `Altitude (m)` | no | Metres. |
| `Speed (km/h)` | no | Calculated from position if missing. |
| `Heading (deg)` | no | Course over ground, 0 = north, clockwise. |
| `Longitudinal (g)` | no | Positive = accelerating. |
| `Lateral (g)` | no | Positive = turning right. |
| `Vertical (g)` | no | Omitted when the phone's mount couldn't be calibrated. |
| `GPS Accuracy (m)` | no | Horizontal accuracy of the source fix. |
| `GPS Fix` | no | `1` = row at a real GPS fix, `0` = interpolated row. |

## Logger export pipeline
1. Drop fixes with accuracy worse than 30 m and impossible jumps.
2. Interpolate the ~1 Hz GPS fixes to a 10 Hz grid using GPS velocity. Gaps over 3 s are not bridged.
3. Work out how the phone is mounted by matching the 50 Hz accelerometer against GPS speed and heading changes. If that match is weak, g-forces are derived from GPS instead, and `G-Force Source` says so.
4. Label laps with the directed timing gates from `tracks.json`.

Phone GPS updates about once a second, so lap and sector times are accurate to roughly ±0.1–0.5 s.
