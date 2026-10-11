// Import pipeline: CSV file -> stored, analysed session record.

import { analyzeSession, summarize } from '../lib/analysis';
import { parseFile } from '../lib/csv/client';
import { newId, saveSession } from '../lib/storage';
import type { SessionAnalysis, SessionRecord, SessionSummary, TrackDef } from '../lib/types';
import type { ImportOutcome } from '../components/ImportPanel';

export interface LoadedSession {
  rec: SessionRecord;
  a: SessionAnalysis;
}

function sessionName(meta: Record<string, string>, fileName: string): string {
  const pick = (k: string) => Object.entries(meta).find(([key]) => key.toLowerCase() === k)?.[1]?.trim();
  return pick('session') || pick('name') || pick('title') || fileName.replace(/\.(csv|txt|tsv)$/i, '');
}

export async function importFile(
  file: File,
  tracks: TrackDef[],
): Promise<{ outcome: ImportOutcome; loaded?: LoadedSession; summary?: SessionSummary }> {
  let res;
  try {
    res = await parseFile(file);
  } catch (e) {
    return { outcome: { fileName: file.name, ok: false, error: e instanceof Error ? e.message : String(e) } };
  }
  if (!res.ok) return { outcome: { fileName: file.name, ok: false, error: res.error, details: res.details } };
  const s = res.session;
  const rec: SessionRecord = {
    id: newId(),
    name: sessionName(s.meta, file.name),
    fileName: file.name,
    importedAt: new Date().toISOString(),
    date: s.date,
    meta: s.meta,
    channels: s.channels,
    report: s.report,
    customGate: null,
  };
  const a = analyzeSession(rec, tracks);
  const summary = summarize(rec, a);
  try {
    await saveSession(rec, summary);
  } catch (e) {
    s.report.warnings.push(`Could not save to browser storage (${e instanceof Error ? e.message : 'unknown error'}); the session is open but will not persist.`);
  }
  return { outcome: { fileName: file.name, ok: true, report: s.report, sessionId: rec.id }, loaded: { rec, a }, summary };
}
