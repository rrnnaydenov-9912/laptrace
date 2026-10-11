// Main-thread wrapper around the parser worker.
import type { ParseResult } from '../types';

let worker: Worker | null = null;
let nextId = 1;
const pending = new Map<number, (r: ParseResult) => void>();

function getWorker(): Worker {
  if (!worker) {
    worker = new Worker(new URL('./parse.worker.ts', import.meta.url), { type: 'module' });
    worker.onmessage = (e: MessageEvent<{ id: number; result: ParseResult }>) => {
      const cb = pending.get(e.data.id);
      if (cb) {
        pending.delete(e.data.id);
        cb(e.data.result);
      }
    };
    worker.onerror = (e) => {
      // A crash inside the worker would otherwise leave every import hanging.
      const msg = e.message || 'The file reader stopped unexpectedly.';
      for (const cb of pending.values()) cb({ ok: false, error: `Could not read the file: ${msg}`, details: [] });
      pending.clear();
      worker?.terminate();
      worker = null;
    };
  }
  return worker;
}

export function parseFile(file: File): Promise<ParseResult> {
  return new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, resolve);
    getWorker().postMessage({ id, file });
  });
}
