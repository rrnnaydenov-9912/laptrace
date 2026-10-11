// Display formatting and colour helpers.

/** 61.9 -> "1:01.900"; 9.5 -> "9.500". */
export function fmtLap(s: number | null | undefined, digits = 3): string {
  if (s == null || !Number.isFinite(s)) return '—';
  const neg = s < 0;
  const a = Math.abs(s);
  const m = Math.floor(a / 60);
  const rest = a - m * 60;
  const sec = rest.toFixed(digits).padStart(digits + 3, '0');
  return `${neg ? '-' : ''}${m > 0 ? `${m}:${sec}` : rest.toFixed(digits)}`;
}

export function fmtDelta(s: number | null | undefined, digits = 3): string {
  if (s == null || !Number.isFinite(s)) return '—';
  if (Math.abs(s) < 0.5 * 10 ** -digits) return (0).toFixed(digits);
  return `${s > 0 ? '+' : '−'}${Math.abs(s).toFixed(digits)}`;
}

export function fmtSpeed(v: number | null | undefined): string {
  return v == null || !Number.isFinite(v) ? '—' : v.toFixed(0);
}

export function fmtDuration(s: number): string {
  if (!Number.isFinite(s)) return '—';
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = Math.round(s % 60);
  return h > 0 ? `${h}h ${m}m` : m > 0 ? `${m}m ${sec}s` : `${sec}s`;
}

export function fmtDist(m: number): string {
  return m >= 1000 ? `${(m / 1000).toFixed(2)} km` : `${Math.round(m)} m`;
}

export function fmtDate(iso: string | null): string {
  if (!iso) return 'Undated';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return 'Undated';
  return d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

/** Speed ramp: blue (slow) → cyan → green → yellow → red (fast). */
export function speedColor(v: number, min: number, max: number): string {
  const t = max > min ? Math.min(1, Math.max(0, (v - min) / (max - min))) : 0.5;
  const hue = 235 * (1 - t);
  return `hsl(${hue.toFixed(0)} 90% ${t > 0.45 && t < 0.75 ? 45 : 50}%)`;
}

export const LAP_PALETTE = [
  '#ff2d2d', '#2e9bff', '#ffb300', '#18c37e', '#d14bff', '#ff7a1a', '#00c2c7', '#e8559b',
];
