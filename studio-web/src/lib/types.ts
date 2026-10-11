// Shared data types for Laptrace Studio.

export interface LatLon {
  lat: number;
  lon: number;
}

/** Directed timing line. A crossing counts when travel bearing is within ±90° of travelBearing. */
export interface Gate {
  id: string;
  label: string;
  start: LatLon;
  end: LatLon;
  travelBearing: number;
}

export interface TrackDef {
  id: string;
  name: string;
  country?: string;
  center: LatLon;
  radiusMeters: number;
  gates: Gate[];
  userDefined?: boolean;
}

/** Column-oriented telemetry. Speed in km/h, g channels in g, time in seconds. */
export interface Channels {
  t: Float64Array;
  lat: Float64Array;
  lon: Float64Array;
  speed: Float32Array;
  alt: Float32Array | null;
  heading: Float32Array | null;
  gLong: Float32Array | null;
  gLat: Float32Array | null;
  gVert: Float32Array | null;
  accuracy: Float32Array | null;
  /** 1 = real GPS fix row, 0 = interpolated row. */
  fix: Uint8Array | null;
  /** Raw lap label per row, or null when the file has no Lap column. */
  lap: string[] | null;
}

export interface ColumnMapping {
  header: string;
  field: string;
  unit: string | null;
}

export interface ImportReport {
  fileName: string;
  rows: number;
  droppedRows: number;
  durationS: number;
  sampleRateHz: number;
  gpsFixRateHz: number | null;
  interpolatedShare: number | null;
  delimiter: string;
  columns: ColumnMapping[];
  ignoredColumns: string[];
  warnings: string[];
  speedDerived: boolean;
  gAxesConfirmed: boolean;
  timeIsAbsolute: boolean;
}

export interface ParsedSession {
  channels: Channels;
  meta: Record<string, string>;
  /** ISO date-time of the session start, when known. */
  date: string | null;
  report: ImportReport;
}

export type ParseResult =
  | { ok: true; session: ParsedSession }
  | { ok: false; error: string; details: string[] };

export interface SessionRecord {
  id: string;
  name: string;
  fileName: string;
  importedAt: string;
  date: string | null;
  meta: Record<string, string>;
  channels: Channels;
  report: ImportReport;
  /** User-defined start/finish line for unknown tracks. */
  customGate: Gate | null;
}

export interface SessionSummary {
  id: string;
  name: string;
  fileName: string;
  importedAt: string;
  date: string | null;
  trackId: string | null;
  trackName: string | null;
  bestLap: number | null;
  timedLaps: number;
  durationS: number;
  center: LatLon;
  favorite?: boolean;
  /** True for a road drive (no laps). Missing on summaries saved before drive mode. */
  drive?: boolean;
  /** Metres, set for drives. */
  distance?: number;
}

export type LapKind = 'out' | 'timed' | 'in' | 'pit' | 'run';

/** Lap boundaries as fractional sample positions (index + fraction towards next sample). */
export interface LapRange {
  label: string;
  kind: LapKind;
  number: number | null;
  pStart: number;
  pEnd: number;
}

export interface LapData {
  key: string;
  sessionId: string;
  index: number;
  label: string;
  kind: LapKind;
  number: number | null;
  startTime: number;
  time: number;
  /** Elapsed seconds from lap start. */
  t: Float64Array;
  lat: Float64Array;
  lon: Float64Array;
  speed: Float32Array;
  gLong: Float32Array | null;
  gLat: Float32Array | null;
  /** Cumulative distance in metres. */
  dist: Float64Array;
  length: number;
  maxSpeed: number;
  minSpeed: number;
  sectors: number[] | null;
}

export type SectorSource = 'track' | 'virtual' | 'none';
export type LapSource = 'track-gates' | 'custom-gate' | 'csv' | 'single';

export interface SessionAnalysis {
  sessionId: string;
  laps: LapData[];
  bestLapIndex: number | null;
  theoreticalBest: number | null;
  bestSectors: number[] | null;
  sectorSource: SectorSource;
  sectorGates: Gate[];
  startFinish: Gate | null;
  lapSource: LapSource;
  track: TrackDef | null;
  hasG: boolean;
  /** True when the data looks like 1 Hz-origin phone GPS (interpolated rows or low rate). */
  lowRateGps: boolean;
  gpsHz: number;
  center: LatLon;
}
