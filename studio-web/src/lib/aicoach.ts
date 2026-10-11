// AI Coach: turns the rule-based facts into a friendly debrief using the
// driver's own Anthropic API key, called straight from the browser. The model
// only writes words; every number it may use is in the facts, and the reply is
// checked against them before it is shown.

import type { Consistency } from './coach';
import { fmtLap, speedFactor, speedUnit } from './format';
import type { Goal, GoalProgress, Opportunity } from './insights';
import { causeLabel, fmtGoalValue, goalCopy, metricName } from './insights';

export const AI_MODELS = [
  { id: 'claude-sonnet-5-5', label: 'Claude Sonnet 5.5 (best)' },
  { id: 'claude-haiku-4-5-20251001', label: 'Claude Haiku 4.5 (fast, cheaper)' },
] as const;

export const KEY_STORAGE = 'laptrace-anthropic-key';
export const MODEL_STORAGE = 'laptrace-ai-model';

export type Facts = Record<string, unknown>;

export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

export const SYSTEM_PROMPT = `You are a calm, encouraging driving coach for people who are new to track days.
You are given FACTS as JSON, measured from the driver's GPS data. Rules:
- Use only numbers that appear in FACTS. Do not estimate, round differently, convert units or invent any figure. If a number is not in FACTS, describe it in words without a number.
- Never give advice about the racing line, track position or where to place the car: GPS on a phone cannot see it accurately.
- Safety first. Suggest small, gradual changes (a few metres, a little speed at a time). Never encourage risk, and remind the driver to stay within their limits and follow track rules and flags.
- Plain language, no jargon without a short explanation. Speak directly to the driver ("you").
- Respect the coaching order: consistency first, then braking, then corner speed, then throttle.
- If FACTS contains "goal" or "goalProgress", say how they did on it.
- If gpsNote is present, mention once that small differences may be measurement noise.
Format the debrief in Markdown exactly like this:
## Summary
Two or three sentences.
## Focus for next session
- Three bullet points, most valuable first, each naming the corner and the measured difference.
## Drill
One short exercise to practise the first focus point.
For follow-up questions, answer briefly in the same style and with the same rules.`;

export function factsMessage(facts: Facts): string {
  return `FACTS:\n${JSON.stringify(facts, null, 1)}\n\nWrite my session debrief.`;
}

export class AiError extends Error {
  kind: 'key' | 'rate' | 'network' | 'server' | 'model';
  constructor(kind: AiError['kind'], message: string) {
    super(message);
    this.kind = kind;
  }
}

/** Call the Anthropic Messages API from the browser with the driver's own key. */
export async function callClaude(apiKey: string, model: string, system: string, messages: ChatMessage[], signal?: AbortSignal): Promise<string> {
  let res: Response;
  try {
    res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'anthropic-dangerous-direct-browser-access': 'true',
      },
      body: JSON.stringify({ model, max_tokens: 1200, system, messages }),
      signal,
    });
  } catch (e) {
    if ((e as Error).name === 'AbortError') throw e;
    throw new AiError('network', 'Could not reach the AI service. Check your internet connection.');
  }
  if (!res.ok) {
    let detail = '';
    try {
      const j = await res.json();
      detail = j?.error?.message ?? '';
    } catch { /* ignore */ }
    if (res.status === 401 || res.status === 403) throw new AiError('key', 'The API key was rejected. Check it in the AI Coach settings.');
    if (res.status === 429) throw new AiError('rate', 'Too many requests or no credit left on this key. Try again in a minute.');
    if (res.status === 404 || res.status === 400) throw new AiError('model', `The AI service refused the request${detail ? `: ${detail}` : '.'}`);
    throw new AiError('server', `The AI service had a problem (${res.status}). Try again shortly.`);
  }
  const j = await res.json();
  const text = (j?.content ?? []).filter((b: { type: string }) => b.type === 'text').map((b: { text: string }) => b.text).join('');
  if (!text) throw new AiError('server', 'The AI returned an empty answer.');
  return text;
}

// --- Facts -------------------------------------------------------------------


export interface FactsInput {
  track: string | null;
  date: string | null;
  vehicle: string | null;
  timedLaps: { label: string; time: number; excluded: boolean }[];
  reference: { label: string; time: number };
  target: { time: number; gain: number } | null;
  bestThree: { avg: number; from: string; to: string } | null;
  opps: Opportunity[];
  cons: Consistency;
  goal: Goal | null;
  goalProgress: GoalProgress | null;
  nextGoal: Goal | null;
  lowRateGps: boolean;
}

const r2 = (v: number) => Math.round(v * 100) / 100;
const r1 = (v: number) => Math.round(v * 10) / 10;

/** Everything the AI may say, already rounded and in the driver's units. */
export function buildFacts(i: FactsInput): Facts {
  const k = speedFactor();
  const sp = (v: number) => Math.round(v * k);
  const counted = i.timedLaps.filter((l) => !l.excluded);
  const facts: Facts = {
    speedUnit: speedUnit(),
    track: i.track ?? 'unknown track',
    date: i.date ?? undefined,
    vehicle: i.vehicle ?? undefined,
    timedLapCount: counted.length,
    lapTimes: counted.map((l) => ({ lap: l.label, time: fmtLap(l.time) })),
    excludedLaps: i.timedLaps.filter((l) => l.excluded).map((l) => l.label),
    referenceLap: { lap: i.reference.label, time: fmtLap(i.reference.time) },
    targetLap: i.target ? { time: fmtLap(i.target.time), gainSeconds: r2(i.target.gain), explanation: 'reference lap plus the 3 biggest corner gains already shown on other laps' } : undefined,
    bestThreeConsecutiveAverage: i.bestThree ? { time: fmtLap(i.bestThree.avg), laps: `${i.bestThree.from}–${i.bestThree.to}` } : undefined,
    lapTimeSpreadSeconds: i.cons.lapTimeSd != null ? r1(i.cons.lapTimeSd) : undefined,
    leastConsistentCorner: i.cons.worstCorner ? { corner: i.cons.worstCorner.corner, minSpeedSpread: r1(i.cons.worstCorner.sd * k) } : undefined,
    opportunities: i.opps.slice(0, 5).map((o) => {
      const d: Record<string, unknown> = {
        corner: o.corner,
        gainSeconds: r2(o.gain),
        fasterLap: o.fromLabel,
        mainDifference: causeLabel(o.cause),
      };
      if (o.refValue != null && o.bestValue != null) {
        if (o.cause === 'braking') { d.brakeLaterByMetres = Math.round(o.bestValue - o.refValue); }
        else if (o.cause === 'throttle') { d.throttleEarlierByMetres = Math.round(o.refValue - o.bestValue); }
        else if (o.cause === 'minSpeed' || o.cause === 'exit') {
          d.referenceSpeed = sp(o.refValue);
          d.fasterLapSpeed = sp(o.bestValue);
          d.speedDifference = sp(o.bestValue) - sp(o.refValue);
        }
      }
      return d;
    }),
  };
  if (i.goal) {
    const c = goalCopy(i.goal);
    facts.goal = { title: c.title, measuredAs: metricName(i.goal.skill), startedAt: fmtGoalValue(i.goal.skill, i.goal.baseline), target: fmtGoalValue(i.goal.skill, i.goal.target) };
    if (i.goalProgress) {
      const p = i.goalProgress;
      facts.goalProgress = p.note ? { note: p.note } : {
        lapsMeasured: p.laps, lapsOnTarget: p.hits,
        best: fmtGoalValue(i.goal.skill, p.best), typical: fmtGoalValue(i.goal.skill, p.median),
        achieved: p.achieved,
      };
    }
  }
  if (i.nextGoal) {
    const c = goalCopy(i.nextGoal);
    facts.suggestedNextGoal = { title: c.title, why: c.why, how: c.how };
  }
  if (i.lowRateGps) facts.gpsNote = 'Phone GPS updates about once a second, so differences under about 0.2 s or 5 m may be noise.';
  return JSON.parse(JSON.stringify(facts));
}

// --- Number verification ----------------------------------------------------

const NUM_RE = /(\d+):(\d{2}(?:\.\d+)?)|[-−+±]?\d+(?:[.,]\d+)?/g;

interface Num { value: number; decimals: number }

/** Every number in a text, with m:ss.xxx lap times converted to seconds. */
export function extractNumbers(text: string): Num[] {
  const out: Num[] = [];
  for (const m of text.matchAll(NUM_RE)) {
    if (m[1] != null) {
      const sec = m[2];
      const decimals = sec.includes('.') ? sec.split('.')[1].length : 0;
      out.push({ value: Number(m[1]) * 60 + Number(sec), decimals });
      continue;
    }
    const raw = m[0].replace(/[−]/g, '-').replace(/[+±]/g, '').replace(',', '.');
    const decimals = raw.includes('.') ? raw.split('.')[1].length : 0;
    out.push({ value: Math.abs(Number(raw)), decimals });
  }
  return out;
}

function collect(v: unknown, out: number[]): void {
  if (typeof v === 'number' && Number.isFinite(v)) out.push(Math.abs(v));
  else if (typeof v === 'string') for (const n of extractNumbers(v)) out.push(n.value);
  else if (Array.isArray(v)) for (const x of v) collect(x, out);
  else if (v && typeof v === 'object') for (const x of Object.values(v)) collect(x, out);
}

export interface Verification {
  ok: boolean;
  /** Numbers in the text that could not be traced to the facts. */
  unknown: string[];
}

/**
 * Check every number in `text` matches a number in `facts`, to the precision
 * written. Small whole numbers (1–10) are allowed for counts like "3 points".
 * Facts carry ready-made differences, so the model never has to subtract.
 */
export function verifyNumbers(text: string, facts: Facts): Verification {
  const known: number[] = [];
  collect(facts, known);
  const unknown: string[] = [];
  for (const n of extractNumbers(text)) {
    if (Number.isInteger(n.value) && n.decimals === 0 && n.value <= 10) continue;
    const tol = 0.5 * 10 ** -n.decimals + 1e-9;
    if (known.some((k) => Math.abs(k - n.value) <= tol)) continue;
    unknown.push(n.decimals ? n.value.toFixed(n.decimals) : String(n.value));
  }
  return { ok: unknown.length === 0, unknown: [...new Set(unknown)] };
}

// --- Minimal safe Markdown ---------------------------------------------------

export type MdBlock =
  | { type: 'h'; text: string }
  | { type: 'p'; text: string }
  | { type: 'ul'; items: string[] };

/** Headings, paragraphs and "- " lists. Output is rendered as text, never HTML. */
export function parseMarkdown(src: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  let para: string[] = [];
  let list: string[] | null = null;
  const flush = () => {
    if (para.length) blocks.push({ type: 'p', text: para.join(' ') });
    para = [];
    if (list) blocks.push({ type: 'ul', items: list });
    list = null;
  };
  for (const raw of src.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) { flush(); continue; }
    const h = /^#{1,6}\s+(.*)$/.exec(line);
    if (h) { flush(); blocks.push({ type: 'h', text: h[1] }); continue; }
    const li = /^(?:[-*•]|\d+[.)])\s+(.*)$/.exec(line);
    if (li) {
      if (para.length) { blocks.push({ type: 'p', text: para.join(' ') }); para = []; }
      (list ??= []).push(li[1]);
      continue;
    }
    if (list) { blocks.push({ type: 'ul', items: list }); list = null; }
    para.push(line);
  }
  flush();
  return blocks;
}

/** Split "**bold**" spans for rendering as <strong>. */
export function splitBold(text: string): { text: string; bold: boolean }[] {
  const parts: { text: string; bold: boolean }[] = [];
  const re = /\*\*(.+?)\*\*/g;
  let last = 0;
  for (const m of text.matchAll(re)) {
    if (m.index! > last) parts.push({ text: text.slice(last, m.index), bold: false });
    parts.push({ text: m[1], bold: true });
    last = m.index! + m[0].length;
  }
  if (last < text.length) parts.push({ text: text.slice(last), bold: false });
  return parts;
}

// --- Key storage (the driver's own browser only) ----------------------------

export function readStoredKey(): string {
  try {
    return localStorage.getItem(KEY_STORAGE) ?? sessionStorage.getItem(KEY_STORAGE) ?? '';
  } catch {
    return '';
  }
}

export function storeKey(key: string, remember: boolean): void {
  try {
    localStorage.removeItem(KEY_STORAGE);
    sessionStorage.removeItem(KEY_STORAGE);
    if (!key) return;
    (remember ? localStorage : sessionStorage).setItem(KEY_STORAGE, key);
  } catch { /* storage blocked: key lives in memory only */ }
}

export function keyIsRemembered(): boolean {
  try {
    return !!localStorage.getItem(KEY_STORAGE);
  } catch {
    return false;
  }
}
