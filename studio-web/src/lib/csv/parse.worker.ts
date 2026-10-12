// Web Worker: parses a CSV file off the main thread.
import { MAX_BYTES, parseCsv } from './parse';
import type { ParseResult } from '../types';

self.onmessage = async (e: MessageEvent<{ id: number; file: File }>) => {
  const { id, file } = e.data;
  let result: ParseResult;
  try {
    if (file.size > MAX_BYTES) {
      result = {
        ok: false,
        error: `"${file.name}" is too large (${(file.size / 1048576).toFixed(1)} MB). The limit is 40 MB.`,
        details: [],
      };
    } else {
      const text = await file.text();
      result = parseCsv(text, file.name);
    }
  } catch (err) {
    result = { ok: false, error: `Could not read "${file.name}".`, details: [String(err)] };
  }
  const transfer: Transferable[] = [];
  if (result.ok) {
    const c = result.session.channels;
    for (const a of [c.t, c.lat, c.lon, c.speed, c.alt, c.heading, c.gLong, c.gLat, c.gVert, c.accuracy, c.fix,
      c.rpm, c.throttle, c.pedal, c.load, c.obdSpeed, c.coolant, c.oil, c.intake]) {
      if (a) transfer.push(a.buffer as ArrayBuffer);
    }
  }
  (self as unknown as Worker).postMessage({ id, result }, transfer);
};
