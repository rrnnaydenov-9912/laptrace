// CSV telemetry parser. Pure function: text in, channels + import report out.
// Follows the shared CSV import contract (shared/CSV-FORMAT.md).

import { haversine, median } from '../geo';
import type { Channels, ColumnMapping, ImportReport, ParseResult } from '../types';

export const MAX_BYTES = 40 * 1024 * 1024;
export const MAX_ROWS = 250_000;
export const MAX_COLUMNS = 128;
const MAX_SPEED_KMH = 650;

type Field =
  | 'time' | 'lap' | 'lat' | 'lon' | 'alt' | 'speed' | 'heading'
  | 'gLong' | 'gLat' | 'gVert' | 'accuracy' | 'fix' | 'gx' | 'gy' | 'gz';

const FIELD_LABEL: Record<Field, string> = {
  time: 'Time', lap: 'Lap', lat: 'Latitude', lon: 'Longitude', alt: 'Altitude', speed: 'Speed',
  heading: 'Heading', gLong: 'Longitudinal g', gLat: 'Lateral g', gVert: 'Vertical g',
  accuracy: 'GPS accuracy', fix: 'GPS fix', gx: 'G-force X', gy: 'G-force Y', gz: 'G-force Z',
};

const ALIASES: Record<Field, string[]> = {
  time: ['time', 'timestamp', 'utctime', 'gpstime', 'datetime', 'elapsed', 'elapsedtime', 'sessiontime', 't', 'unixtime', 'epoch'],
  lap: ['lap', 'lapnumber', 'lapno', 'lapindex', 'lapnum', 'lapcount'],
  lat: ['latitude', 'lat', 'gpslatitude', 'gpslat'],
  lon: ['longitude', 'lon', 'lng', 'long', 'gpslongitude', 'gpslon', 'gpslng'],
  alt: ['altitude', 'alt', 'elevation', 'height', 'gpsaltitude'],
  speed: ['speed', 'gpsspeed', 'velocity', 'groundspeed', 'spd'],
  heading: ['heading', 'course', 'bearing', 'cog', 'gpsheading', 'courseoverground'],
  gLong: ['longitudinal', 'longitudinalg', 'longitudinalacceleration', 'longitudinalaccel', 'longacc', 'longg', 'glong', 'gforcelong', 'accellong', 'longaccel'],
  gLat: ['lateral', 'lateralg', 'lateralacceleration', 'lateralaccel', 'latacc', 'latg', 'glat', 'gforcelat', 'accellat', 'lataccel'],
  gVert: ['vertical', 'verticalg', 'verticalacceleration', 'verticalaccel', 'vertg', 'gvert', 'gforcevert'],
  accuracy: ['gpsaccuracy', 'accuracy', 'horizontalaccuracy', 'hacc', 'posaccuracy'],
  fix: ['gpsfix', 'fix', 'fixtype', 'gpsfixtype', 'isfix'],
  gx: ['gforcex', 'gx', 'accx', 'accelx', 'accelerationx', 'xg', 'gforcexg'],
  gy: ['gforcey', 'gy', 'accy', 'accely', 'accelerationy', 'yg', 'gforceyg'],
  gz: ['gforcez', 'gz', 'accz', 'accelz', 'accelerationz', 'zg', 'gforcezg'],
};

const FIELD_ORDER = Object.keys(ALIASES) as Field[];
// Unit suffixes that may be glued to a header without brackets, e.g. "SpeedKmh", "LateralG".
const UNIT_SUFFIXES = ['kmh', 'kph', 'mph', 'mps', 'ms2', 'knots', 'kts', 'kn', 'mg', 'deg', 'ms', 'g', 'm', 's'];

export function normalizeName(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, '');
}

export function normalizeUnit(u: string | null): string | null {
  if (u == null) return null;
  const s = u.toLowerCase().replace(/²/g, '2').replace(/\s+/g, '').replace(/\^/g, '');
  if (s === '') return null;
  if (['km/h', 'kmh', 'kph', 'kmph', 'km/hr'].includes(s)) return 'kmh';
  if (['mph', 'mi/h'].includes(s)) return 'mph';
  if (['m/s', 'mps', 'ms-1', 'm·s-1'].includes(s)) return 'ms';
  if (['kn', 'kt', 'kts', 'knot', 'knots'].includes(s)) return 'kn';
  if (['m/s2', 'ms2', 'ms-2', 'm/s/s', 'm/sec2'].includes(s)) return 'ms2';
  if (['g', 'gs', 'gforce'].includes(s)) return 'g';
  if (s === 'mg') return 'mg';
  if (['deg', '°', 'degrees', 'degree'].includes(s)) return 'deg';
  if (['s', 'sec', 'secs', 'seconds'].includes(s)) return 's';
  if (s === 'm' || s === 'meters' || s === 'metres') return 'm';
  return s;
}

interface HeaderCell {
  raw: string;
  field: Field | null;
  unit: string | null;
}

function splitBracketUnit(raw: string): { base: string; unit: string | null } {
  const m = raw.match(/^(.*?)[\s_]*[([{]\s*([^)\]}]*?)\s*[)\]}]\s*$/);
  if (m) return { base: m[1], unit: m[2] };
  return { base: raw, unit: null };
}

export function matchHeader(raw: string): { field: Field | null; unit: string | null } {
  const { base, unit } = splitBracketUnit(raw.trim());
  const nBase = normalizeName(base);
  const nFull = normalizeName(raw);
  for (const f of FIELD_ORDER) {
    const aliases = ALIASES[f];
    if (aliases.includes(nBase)) return { field: f, unit: normalizeUnit(unit) };
    if (aliases.includes(nFull)) return { field: f, unit: normalizeUnit(unit) };
  }
  if (unit == null) {
    for (const suf of UNIT_SUFFIXES) {
      if (!nFull.endsWith(suf) || nFull.length <= suf.length) continue;
      const stem = nFull.slice(0, -suf.length);
      for (const f of FIELD_ORDER) {
        if (ALIASES[f].includes(stem)) return { field: f, unit: normalizeUnit(suf) };
      }
    }
  }
  return { field: null, unit: normalizeUnit(unit) };
}

/** Split one CSV line, honouring double quotes. */
export function splitLine(line: string, delim: string): string[] {
  if (!line.includes('"')) return line.split(delim).map((c) => c.trim());
  const out: string[] = [];
  let cur = '';
  let inQ = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQ) {
      if (ch === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; } else inQ = false;
      } else cur += ch;
    } else if (ch === '"') inQ = true;
    else if (ch === delim) { out.push(cur.trim()); cur = ''; }
    else cur += ch;
  }
  out.push(cur.trim());
  return out;
}

function parseNumber(s: string, decimalComma: boolean): number {
  if (s === '' || s == null) return NaN;
  let v = s;
  if (decimalComma && /^[-+]?\d*,\d+(e[-+]?\d+)?$/i.test(v)) v = v.replace(',', '.');
  const n = Number(v);
  return Number.isFinite(n) ? n : NaN;
}

function parseCoord(s: string, decimalComma: boolean): number {
  const m = s.match(/^([-+]?\d+(?:[.,]\d+)?)\s*°?\s*([NSEWnsew])$/);
  if (m) {
    const v = parseNumber(m[1].replace(',', '.'), false);
    const h = m[2].toUpperCase();
    return h === 'S' || h === 'W' ? -Math.abs(v) : Math.abs(v);
  }
  return parseNumber(s, decimalComma);
}

type TimeMode = 'unix-s' | 'unix-ms' | 'unix-us' | 'unix-ns' | 'elapsed-s' | 'elapsed-ms' | 'clock' | 'iso';

const CLOCK_RE = /^(\d{1,2}):(\d{1,2})(?::(\d{1,2}(?:[.,]\d+)?))?$/;
const MMSS_RE = /^(\d{1,3}):(\d{1,2}[.,]\d+)$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}/;

function detectTimeMode(sample: string, unit: string | null, decimalComma: boolean): TimeMode | null {
  if (ISO_RE.test(sample)) return 'iso';
  if (MMSS_RE.test(sample) || CLOCK_RE.test(sample)) return 'clock';
  const v = parseNumber(sample, decimalComma);
  if (!Number.isFinite(v)) return null;
  const a = Math.abs(v);
  if (a > 1e17) return 'unix-ns';
  if (a > 1e14) return 'unix-us';
  if (a > 1e11) return 'unix-ms';
  if (a > 1e8) return 'unix-s';
  if (unit === 'ms') return 'elapsed-ms';
  return 'elapsed-s';
}

function parseTime(s: string, mode: TimeMode, decimalComma: boolean): number {
  switch (mode) {
    case 'iso': {
      let v = s.replace(' ', 'T');
      if (!/(Z|[+-]\d{2}:?\d{2})$/i.test(v)) v += 'Z';
      const ms = Date.parse(v);
      return Number.isFinite(ms) ? ms / 1000 : NaN;
    }
    case 'clock': {
      let m = s.match(MMSS_RE);
      if (m) return Number(m[1]) * 60 + Number(m[2].replace(',', '.'));
      m = s.match(CLOCK_RE);
      if (!m) return NaN;
      const sec = m[3] != null ? Number(m[3].replace(',', '.')) : 0;
      return Number(m[1]) * 3600 + Number(m[2]) * 60 + sec;
    }
    case 'unix-ns': return parseNumber(s, decimalComma) / 1e9;
    case 'unix-us': return parseNumber(s, decimalComma) / 1e6;
    case 'unix-ms':
    case 'elapsed-ms': return parseNumber(s, decimalComma) / 1e3;
    default: return parseNumber(s, decimalComma);
  }
}

function speedFactor(unit: string | null): number {
  switch (unit) {
    case 'mph': return 1.609344;
    case 'ms':
    case 'mps': return 3.6;
    case 'kn':
    case 'kts': return 1.852;
    default: return 1;
  }
}

function gFactor(unit: string | null): number {
  if (unit === 'mg') return 1 / 1000;
  if (unit === 'ms2') return 1 / 9.80665;
  return 1;
}

const DELIMS: { ch: string; name: string }[] = [
  { ch: ',', name: 'comma' },
  { ch: ';', name: 'semicolon' },
  { ch: '\t', name: 'tab' },
  { ch: '|', name: 'pipe' },
];

function fail(error: string, details: string[] = []): ParseResult {
  return { ok: false, error, details };
}

function sanitizeLabel(s: string): string {
  return s.replace(/[<>"'&]/g, '').slice(0, 40).trim();
}

export function parseCsv(text: string, fileName = 'session.csv'): ParseResult {
  if (text.length > MAX_BYTES) {
    return fail(`The file is too large (${(text.length / 1048576).toFixed(1)} MB). The limit is 40 MB.`);
  }
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  const lines = text.split(/\r\n|\n|\r/);
  if (lines.every((l) => l.trim() === '')) return fail('The file is empty.');

  // 1. Find the header row and delimiter.
  let headerLine = -1;
  let delim = ',';
  let delimName = 'comma';
  let headerCells: HeaderCell[] = [];
  let bestPartial: { found: Field[]; cells: string[] } | null = null;
  const scanLimit = Math.min(lines.length, 300);
  for (let i = 0; i < scanLimit && headerLine < 0; i++) {
    const line = lines[i];
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
    for (const d of DELIMS) {
      if (!line.includes(d.ch)) continue;
      const cells = splitLine(line, d.ch);
      const mapped = cells.map((c) => ({ raw: c, ...matchHeader(c) }));
      const found = new Set(mapped.map((m) => m.field).filter((f): f is Field => f != null));
      const req = (['time', 'lat', 'lon'] as Field[]).filter((f) => found.has(f));
      if (req.length === 3) {
        headerLine = i;
        delim = d.ch;
        delimName = d.name;
        headerCells = mapped;
        break;
      }
      if (req.length > 0 && cells.length >= 3 && (!bestPartial || req.length > bestPartial.found.length)) {
        bestPartial = { found: req, cells };
      }
    }
  }
  if (headerLine < 0) {
    if (bestPartial) {
      const missing = (['time', 'lat', 'lon'] as Field[]).filter((f) => !bestPartial!.found.includes(f));
      return fail(
        `Missing required column${missing.length > 1 ? 's' : ''}: ${missing.map((f) => FIELD_LABEL[f]).join(', ')}.`,
        [
          `Found columns: ${bestPartial.cells.slice(0, 20).join(', ')}`,
          'Every file needs Time, Latitude and Longitude columns (e.g. "Time,Lap,Latitude,Longitude,Speed (km/h)").',
        ],
      );
    }
    return fail('This does not look like a telemetry CSV: no header row with Time, Latitude and Longitude was found.', [
      'Checked the first 300 lines for a header using comma, semicolon, tab and pipe delimiters.',
    ]);
  }

  const warnings: string[] = [];
  const nCols = headerCells.length;
  if (nCols > MAX_COLUMNS) return fail(`The file has ${nCols} columns. The limit is ${MAX_COLUMNS}.`);
  const seen = new Set<string>();
  for (const h of headerCells) {
    const k = h.raw.toLowerCase();
    if (seen.has(k)) return fail(`Column names must be unique: "${h.raw}" appears more than once.`);
    seen.add(k);
  }

  // 2. Metadata rows above the header.
  const meta: Record<string, string> = {};
  for (let i = 0; i < headerLine; i++) {
    const line = lines[i];
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
    const cells = splitLine(line, delim);
    if (cells.length >= 2 && cells[0] !== '') meta[cells[0]] = cells.slice(1).join(delim === ',' ? ', ' : ' ').trim();
  }

  const decimalComma = delim !== ',';

  // 3. Optional units row.
  let dataStart = headerLine + 1;
  while (dataStart < lines.length && lines[dataStart].trim() === '') dataStart++;
  if (dataStart < lines.length) {
    const cells = splitLine(lines[dataStart], delim);
    const numeric = cells.filter((c) => c !== '' && Number.isFinite(parseNumber(c, decimalComma))).length;
    const looksUnits = numeric === 0 && cells.some((c) => c !== '') && cells.every((c) => c.length <= 16)
      && !cells.some((c) => ISO_RE.test(c) || CLOCK_RE.test(c) || MMSS_RE.test(c));
    if (looksUnits) {
      cells.forEach((c, j) => {
        if (j < nCols && headerCells[j].unit == null && c !== '') {
          headerCells[j].unit = normalizeUnit(c.replace(/^[([{]|[)\]}]$/g, ''));
        }
      });
      dataStart++;
    }
  }

  // 4. Column assignment.
  const idx: Partial<Record<Field, number>> = {};
  const columns: ColumnMapping[] = [];
  const ignored: string[] = [];
  headerCells.forEach((h, j) => {
    if (h.field && idx[h.field] == null) {
      idx[h.field] = j;
      columns.push({ header: h.raw, field: FIELD_LABEL[h.field], unit: h.unit });
    } else {
      if (h.field) warnings.push(`Column "${h.raw}" duplicates ${FIELD_LABEL[h.field]} and was ignored.`);
      if (h.raw !== '') ignored.push(h.raw);
    }
  });

  let gAxesConfirmed = idx.gLong != null || idx.gLat != null;
  const usesGeneric = idx.gLong == null && idx.gLat == null && (idx.gx != null || idx.gy != null);
  if (usesGeneric) {
    warnings.push('G axes are unconfirmed: assumed X = longitudinal, Y = lateral (positive right), Z = vertical.');
    gAxesConfirmed = false;
  } else if (gAxesConfirmed) {
    for (const f of ['gLong', 'gLat'] as Field[]) {
      const j = idx[f];
      if (j != null && headerCells[j].unit == null) {
        warnings.push(`"${headerCells[j].raw}" has no unit; assuming g.`);
      }
    }
  }
  const gLongCol = usesGeneric ? idx.gx : idx.gLong;
  const gLatCol = usesGeneric ? idx.gy : idx.gLat;
  const gVertCol = idx.gVert ?? (usesGeneric ? idx.gz : undefined);

  // 5. Rows.
  const timeCol = idx.time!;
  const latCol = idx.lat!;
  const lonCol = idx.lon!;
  let timeMode: TimeMode | null = null;
  const timeUnit = headerCells[timeCol].unit;

  const T: number[] = [];
  const LA: number[] = [];
  const LO: number[] = [];
  const SP: number[] = [];
  const AL: number[] = [];
  const HD: number[] = [];
  const GL: number[] = [];
  const GT: number[] = [];
  const GV: number[] = [];
  const AC: number[] = [];
  const FX: number[] = [];
  const LP: string[] = [];

  const spF = speedFactor(idx.speed != null ? headerCells[idx.speed].unit : null);
  const glF = gFactor(gLongCol != null ? headerCells[gLongCol].unit : null);
  const gtF = gFactor(gLatCol != null ? headerCells[gLatCol].unit : null);
  const gvF = gFactor(gVertCol != null ? headerCells[gVertCol].unit : null);

  let malformed = 0;
  let badCoords = 0;
  let badTime = 0;
  let backwards = 0;
  let tooFast = 0;
  let labelFixed = 0;
  let total = 0;
  let clockOffset = 0;
  let lastClockRaw = -Infinity;

  for (let i = dataStart; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
    total++;
    if (total > MAX_ROWS) {
      return fail(`The file has more than ${MAX_ROWS.toLocaleString('en')} data rows (about 7 hours at 10 Hz). Split it into smaller sessions.`);
    }
    const c = splitLine(line, delim);
    if (c.length !== nCols) {
      if (c.length < nCols || c.slice(nCols).some((x) => x !== '')) { malformed++; continue; }
    }
    if (timeMode == null) {
      timeMode = detectTimeMode(c[timeCol], timeUnit, decimalComma);
      if (timeMode == null) {
        return fail(`Unrecognised time format: "${c[timeCol]}" on line ${i + 1}.`, [
          'Supported: Unix seconds/ms/µs/ns, elapsed seconds, HH:MM:SS.sss, MM:SS.s or ISO 8601.',
        ]);
      }
    }
    let t = parseTime(c[timeCol], timeMode, decimalComma);
    if (!Number.isFinite(t)) { badTime++; continue; }
    if (timeMode === 'clock') {
      if (t + 43200 < lastClockRaw) clockOffset += 86400; // crossed midnight
      lastClockRaw = t;
      t += clockOffset;
    }
    const lat = parseCoord(c[latCol], decimalComma);
    const lon = parseCoord(c[lonCol], decimalComma);
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180 || (lat === 0 && lon === 0)) {
      badCoords++;
      continue;
    }
    if (T.length > 0 && t <= T[T.length - 1]) { backwards++; continue; }
    let sp = NaN;
    if (idx.speed != null) {
      sp = Math.abs(parseNumber(c[idx.speed], decimalComma) * spF);
      if (sp > MAX_SPEED_KMH) { tooFast++; continue; }
    }
    T.push(t);
    LA.push(lat);
    LO.push(lon);
    SP.push(sp);
    if (idx.alt != null) AL.push(parseNumber(c[idx.alt], decimalComma));
    if (idx.heading != null) HD.push(parseNumber(c[idx.heading], decimalComma));
    if (gLongCol != null) GL.push(parseNumber(c[gLongCol], decimalComma) * glF);
    if (gLatCol != null) GT.push(parseNumber(c[gLatCol], decimalComma) * gtF);
    if (gVertCol != null) GV.push(parseNumber(c[gVertCol], decimalComma) * gvF);
    if (idx.accuracy != null) AC.push(parseNumber(c[idx.accuracy], decimalComma));
    if (idx.fix != null) {
      const v = c[idx.fix].toLowerCase();
      FX.push(v === 'true' || v === 'yes' || Number(v) >= 1 ? 1 : 0);
    }
    if (idx.lap != null) {
      const raw = c[idx.lap] ?? '';
      const clean = sanitizeLabel(raw);
      if (clean !== raw.trim()) labelFixed++;
      LP.push(clean);
    }
  }

  const n = T.length;
  if (n < 2) {
    const reasons: string[] = [];
    if (total === 0) reasons.push('There are no data rows below the header.');
    if (badCoords) reasons.push(`${badCoords} rows had no valid GPS position (blank, 0,0 or out of range).`);
    if (badTime) reasons.push(`${badTime} rows had an unreadable time.`);
    if (malformed) reasons.push(`${malformed} rows had the wrong number of fields.`);
    return fail('No usable data rows were found.', reasons);
  }

  // Radians check: every coordinate within ±π/2, ±π suggests radians.
  let radiansLike = true;
  for (let i = 0; i < n && radiansLike; i += Math.max(1, Math.floor(n / 200))) {
    if (Math.abs(LA[i]) > 1.5708 || Math.abs(LO[i]) > 3.1416) radiansLike = false;
  }
  if (radiansLike) {
    return fail('Latitude/Longitude look like radians. Please export decimal degrees.');
  }

  if (malformed > 0.1 * total) {
    return fail(`${malformed} of ${total} rows have a different number of fields than the header (${nCols}).`, [
      'Every row needs the same number of fields as the header row.',
    ]);
  }
  if (backwards > 0.2 * total) {
    return fail('The Time column does not increase: too many duplicate or backwards timestamps.', [
      `${backwards} of ${total} rows went backwards or repeated a timestamp.`,
    ]);
  }
  if (malformed) warnings.push(`${malformed} rows with the wrong number of fields were skipped.`);
  if (badCoords) warnings.push(`${badCoords} rows without a valid GPS position were skipped.`);
  if (badTime) warnings.push(`${badTime} rows with an unreadable time were skipped.`);
  if (backwards) warnings.push(`${backwards} rows with duplicate or backwards timestamps were skipped.`);
  if (tooFast) warnings.push(`${tooFast} rows with speed above ${MAX_SPEED_KMH} km/h were skipped.`);
  if (labelFixed) warnings.push(`${labelFixed} lap labels were cleaned (max 40 characters, no <>"'&).`);

  // 6. Speed: use column, fill gaps, or derive from GPS.
  const speed = new Float32Array(n);
  let validSpeed = 0;
  for (let i = 0; i < n; i++) if (Number.isFinite(SP[i])) validSpeed++;
  const speedDerived = validSpeed < n * 0.5;
  if (speedDerived) {
    const raw = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const a = Math.max(0, i - 1);
      const b = Math.min(n - 1, i + 1);
      const dt = T[b] - T[a];
      raw[i] = dt > 0 ? (haversine(LA[a], LO[a], LA[b], LO[b]) / dt) * 3.6 : 0;
    }
    const w = 2;
    for (let i = 0; i < n; i++) {
      let s = 0, k = 0;
      for (let j = Math.max(0, i - w); j <= Math.min(n - 1, i + w); j++) { s += raw[j]; k++; }
      speed[i] = s / k;
    }
    warnings.push(idx.speed != null ? 'The Speed column was mostly empty: speed was calculated from GPS positions.' : 'No Speed column: speed was calculated from GPS positions.');
  } else {
    let last = NaN;
    for (let i = 0; i < n; i++) {
      if (Number.isFinite(SP[i])) last = SP[i];
      speed[i] = Number.isFinite(last) ? last : 0;
    }
  }

  // 7. GPS jumps.
  let jumps = 0;
  for (let i = 1; i < n; i++) {
    const d = haversine(LA[i - 1], LO[i - 1], LA[i], LO[i]);
    if (d > 50 && d / (T[i] - T[i - 1]) > 200) jumps++;
  }
  if (jumps) warnings.push(`${jumps} GPS jump${jumps > 1 ? 's' : ''} detected (position moved >50 m faster than 200 m/s).`);

  const toF32 = (arr: number[], factorCheckName?: string): Float32Array | null => {
    if (arr.length !== n) return null;
    if (arr.every((v) => !Number.isFinite(v))) return null;
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = Number.isFinite(arr[i]) ? arr[i] : NaN;
    if (factorCheckName) {
      const med = median(Array.from(out, Math.abs));
      if (med > 4) {
        for (let i = 0; i < n; i++) out[i] /= 9.80665;
        warnings.push(`${factorCheckName} values look like m/s²; converted to g.`);
      }
    }
    return out;
  };

  const channels: Channels = {
    t: Float64Array.from(T),
    lat: Float64Array.from(LA),
    lon: Float64Array.from(LO),
    speed,
    alt: toF32(AL),
    heading: toF32(HD),
    gLong: gLongCol != null && headerCells[gLongCol].unit == null ? toF32(GL, 'Longitudinal g') : toF32(GL),
    gLat: gLatCol != null && headerCells[gLatCol].unit == null ? toF32(GT, 'Lateral g') : toF32(GT),
    gVert: toF32(GV),
    accuracy: toF32(AC),
    fix: FX.length === n ? Uint8Array.from(FX) : null,
    lap: LP.length === n ? LP : null,
  };

  // 8. Session date.
  const absolute = timeMode != null && timeMode.startsWith('unix') || timeMode === 'iso';
  let date: string | null = null;
  if (absolute) date = new Date(T[0] * 1000).toISOString();
  else {
    const metaDate = meta['Date UTC'] ?? meta['Date'] ?? meta['date'] ?? meta['Session date'];
    if (metaDate) {
      const d = Date.parse(metaDate);
      if (Number.isFinite(d)) {
        date = timeMode === 'clock'
          ? new Date(Math.floor(d / 86400000) * 86400000 + T[0] * 1000).toISOString()
          : new Date(d).toISOString();
      }
    }
  }

  // 9. Report.
  const dts: number[] = [];
  const step = Math.max(1, Math.floor(n / 5000));
  for (let i = 1; i < n; i += step) dts.push(T[i] - T[i - 1]);
  const medDt = median(dts);
  const durationS = T[n - 1] - T[0];
  let gpsFixRateHz: number | null = null;
  let interpolatedShare: number | null = null;
  if (channels.fix) {
    let fixes = 0;
    for (let i = 0; i < n; i++) fixes += channels.fix[i];
    interpolatedShare = 1 - fixes / n;
    gpsFixRateHz = durationS > 0 ? fixes / durationS : null;
  }

  const report: ImportReport = {
    fileName,
    rows: n,
    droppedRows: total - n,
    durationS,
    sampleRateHz: medDt > 0 ? 1 / medDt : 0,
    gpsFixRateHz,
    interpolatedShare,
    delimiter: delimName,
    columns,
    ignoredColumns: ignored,
    warnings,
    speedDerived,
    gAxesConfirmed,
    timeIsAbsolute: absolute,
  };

  return { ok: true, session: { channels, meta, date, report } };
}
