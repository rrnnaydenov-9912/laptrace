// IndexedDB persistence (idb-keyval). Summaries and full records live in
// separate databases so the library list loads without pulling telemetry.

import { createStore, del, entries, get, set } from 'idb-keyval';
import type { SessionRecord, SessionSummary, TrackDef } from './types';
import type { Goal } from './insights';

const summaries = createStore('laptrace-summaries', 'summaries');
const records = createStore('laptrace-sessions', 'sessions');
const userTracks = createStore('laptrace-tracks', 'tracks');
const goals = createStore('laptrace-goals', 'goals');

export async function listSummaries(): Promise<SessionSummary[]> {
  const all = await entries<string, SessionSummary>(summaries);
  return all.map(([, v]) => v).sort((a, b) => (b.date ?? b.importedAt).localeCompare(a.date ?? a.importedAt));
}

export async function saveSession(rec: SessionRecord, summary: SessionSummary): Promise<void> {
  await set(rec.id, rec, records);
  await set(rec.id, summary, summaries);
}

export async function saveSummary(summary: SessionSummary): Promise<void> {
  await set(summary.id, summary, summaries);
}

export function loadSession(id: string): Promise<SessionRecord | undefined> {
  return get<SessionRecord>(id, records);
}

export async function deleteSession(id: string): Promise<void> {
  await del(id, records);
  await del(id, summaries);
}

export async function listUserTracks(): Promise<TrackDef[]> {
  const all = await entries<string, TrackDef>(userTracks);
  return all.map(([, v]) => v);
}

export function saveUserTrack(t: TrackDef): Promise<void> {
  return set(t.id, t, userTracks);
}

export function deleteUserTrack(id: string): Promise<void> {
  return del(id, userTracks);
}

export function newId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** The driver's current goal for a track (one per track). */
export function loadGoal(trackId: string): Promise<Goal | undefined> {
  return get<Goal>(trackId, goals);
}

export function saveGoal(goal: Goal): Promise<void> {
  return set(goal.trackId, goal, goals);
}

export function clearGoal(trackId: string): Promise<void> {
  return del(trackId, goals);
}
