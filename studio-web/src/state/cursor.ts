// Shared cursor (position on the reference lap) linking map, charts and G-G.
// A tiny external store so high-frequency hover updates skip the React tree.

import { useSyncExternalStore } from 'react';

export interface CursorState {
  /** Distance along the reference lap, metres. */
  s: number | null;
  /** Elapsed lap time during playback, seconds (null when hovering). */
  time: number | null;
  /** Who set it, so a source can ignore its own echo. */
  src: string;
}

let state: CursorState = { s: null, time: null, src: '' };
const listeners = new Set<() => void>();

export const cursor = {
  get: () => state,
  set(next: CursorState) {
    if (next.s === state.s && next.time === state.time) return;
    state = next;
    listeners.forEach((l) => l());
  },
  clear() {
    cursor.set({ s: null, time: null, src: 'clear' });
  },
  subscribe(l: () => void) {
    listeners.add(l);
    return () => { listeners.delete(l); };
  },
};

export function useCursor(): CursorState {
  return useSyncExternalStore(cursor.subscribe, cursor.get, cursor.get);
}
