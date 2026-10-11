// Geodesy helpers: distances, bearings, a local planar projection and segment intersection.

export const EARTH_RADIUS = 6371008.8;
const DEG = Math.PI / 180;

export function haversine(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = (lat2 - lat1) * DEG;
  const dLon = (lon2 - lon1) * DEG;
  const a =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * DEG) * Math.cos(lat2 * DEG) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** Initial bearing in degrees, 0 = north, clockwise, range [0, 360). */
export function bearing(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const y = Math.sin((lon2 - lon1) * DEG) * Math.cos(lat2 * DEG);
  const x =
    Math.cos(lat1 * DEG) * Math.sin(lat2 * DEG) -
    Math.sin(lat1 * DEG) * Math.cos(lat2 * DEG) * Math.cos((lon2 - lon1) * DEG);
  return (Math.atan2(y, x) / DEG + 360) % 360;
}

/** Signed smallest difference a - b in degrees, range (-180, 180]. */
export function angleDiff(a: number, b: number): number {
  let d = (a - b) % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}

/** Bearing (deg) of a planar vector where +y = north and +x = east. */
export function xyBearing(dx: number, dy: number): number {
  return (Math.atan2(dx, dy) / DEG + 360) % 360;
}

export interface Projector {
  lat0: number;
  lon0: number;
  x(lat: number, lon: number): number;
  y(lat: number): number;
  lat(y: number): number;
  lon(x: number): number;
}

/** Equirectangular projection around an origin; accurate to well under 0.1% over a few km. */
export function makeProjector(lat0: number, lon0: number): Projector {
  const ky = EARTH_RADIUS * DEG;
  const kx = ky * Math.cos(lat0 * DEG);
  return {
    lat0,
    lon0,
    x: (_lat, lon) => (lon - lon0) * kx,
    y: (lat) => (lat - lat0) * ky,
    lat: (y) => lat0 + y / ky,
    lon: (x) => lon0 + x / kx,
  };
}

/**
 * Intersection of segments P1→P2 and Q1→Q2.
 * Returns u (fraction along P) and v (fraction along Q), or null when they do not cross.
 */
export function segmentIntersection(
  p1x: number, p1y: number, p2x: number, p2y: number,
  q1x: number, q1y: number, q2x: number, q2y: number,
): { u: number; v: number } | null {
  const rx = p2x - p1x;
  const ry = p2y - p1y;
  const sx = q2x - q1x;
  const sy = q2y - q1y;
  const denom = rx * sy - ry * sx;
  if (Math.abs(denom) < 1e-12) return null;
  const qpx = q1x - p1x;
  const qpy = q1y - p1y;
  const u = (qpx * sy - qpy * sx) / denom;
  const v = (qpx * ry - qpy * rx) / denom;
  if (u < 0 || u > 1 || v < 0 || v > 1) return null;
  return { u, v };
}

export function median(values: ArrayLike<number>): number {
  const arr = Array.from(values).filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
  if (arr.length === 0) return NaN;
  const m = arr.length >> 1;
  return arr.length % 2 ? arr[m] : (arr[m - 1] + arr[m]) / 2;
}

export function stdDev(values: number[]): number {
  if (values.length < 2) return 0;
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  return Math.sqrt(values.reduce((a, b) => a + (b - mean) ** 2, 0) / (values.length - 1));
}
