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
  - `Mode`: `Drive` for a road drive (no laps or track; Studio shows the drive view), `Track` otherwise. Missing in older files; readers then treat a recording with no track and no laps as a drive.
  - Optional keys, written only when filled in: `OBD Source` (the reader, when car data was recorded), `Driver`, `Vehicle`, `Notes`, `Video Start UTC` (ISO 8601, the moment "Mark video start" was tapped; use it to sync onboard video).
  - These free-text values are always wrapped in double quotes, with inner quotes doubled (`"Ana ""Ace"" P."`), so commas are safe. Line breaks are folded into single spaces, so every metadata row stays on one line.
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
| `RPM` | no | Engine speed from the OBD reader. |
| `Throttle (%)` | no | Throttle plate position (OBD PID 11), 0–100. |
| `Pedal (%)` | no | Accelerator pedal position (OBD PID 49), 0–100. Closer to what the driver's foot does than `Throttle`. |
| `Engine Load (%)` | no | Calculated engine load (OBD PID 04). |
| `OBD Speed (km/h)` | no | Speed reported by the car (OBD PID 0D). |
| `Coolant (°C)` | no | Coolant temperature (OBD PID 05). |
| `Oil (°C)` | no | Oil temperature (OBD PID 5C). Many cars don't report it. |
| `Intake (°C)` | no | Intake air temperature (OBD PID 0F). |

### Car data (OBD)
The car columns appear only when an OBD reader was connected while recording, and each one only when the car answered that reading. A blank cell means no reading near that moment (the reader was polled at about 5–10 Hz for RPM, throttle and pedal, every few seconds for temperatures). The `OBD Source` metadata row names the reader.

Standard OBD has no brake pressure. Braking is read from `Longitudinal (g)`: below about −0.15 g with the pedal under 5 % counts as braking; pedal under 5 % with no real deceleration counts as coasting.

## Logger export pipeline
1. Drop fixes with accuracy worse than 30 m and impossible jumps.
2. Interpolate the ~1 Hz GPS fixes to a 10 Hz grid using GPS velocity. Gaps over 3 s are not bridged.
3. Work out how the phone is mounted by matching the 50 Hz accelerometer against GPS speed and heading changes. If that match is weak, g-forces are derived from GPS instead, and `G-Force Source` says so.
4. Label laps with the directed timing gates from `tracks.json`.

Phone GPS updates about once a second, so lap and sector times are accurate to roughly ±0.1–0.5 s.
