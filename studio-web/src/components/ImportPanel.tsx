// Drop zone + per-file validation reports.

import { useRef, useState } from 'react';
import { fmtDuration } from '../lib/format';
import type { ImportReport } from '../lib/types';

export interface ImportOutcome {
  fileName: string;
  ok: boolean;
  report?: ImportReport;
  error?: string;
  details?: string[];
  sessionId?: string;
}

const DELIM: Record<string, string> = { ',': 'comma', ';': 'semicolon', '\t': 'tab', '|': 'pipe' };

export function ReportCard({ o, onOpen, onDismiss }: { o: ImportOutcome; onOpen?: () => void; onDismiss: () => void }) {
  if (!o.ok || !o.report) {
    return (
      <div className="report report--error" role="alert">
        <div className="report-head">
          <b>{o.fileName}</b>
          <span className="tag tag--error">Not imported</span>
          <button type="button" className="link" onClick={onDismiss} aria-label="Dismiss">✕</button>
        </div>
        <p>{o.error}</p>
        {o.details && o.details.length > 0 && <ul>{o.details.map((d, i) => <li key={i}>{d}</li>)}</ul>}
      </div>
    );
  }
  const r = o.report;
  return (
    <div className="report">
      <div className="report-head">
        <b>{r.fileName}</b>
        <span className={`tag ${r.warnings.length ? 'tag--warn' : 'tag--ok'}`}>{r.warnings.length ? `${r.warnings.length} warning${r.warnings.length > 1 ? 's' : ''}` : 'Imported'}</span>
        {onOpen && <button type="button" className="link" onClick={onOpen}>Open</button>}
        <button type="button" className="link" onClick={onDismiss} aria-label="Dismiss">✕</button>
      </div>
      <dl className="report-stats">
        <div><dt>Rows</dt><dd>{r.rows.toLocaleString()}{r.droppedRows ? ` (−${r.droppedRows})` : ''}</dd></div>
        <div><dt>Sample rate</dt><dd>{r.sampleRateHz.toFixed(1)} Hz</dd></div>
        {r.gpsFixRateHz != null && <div><dt>GPS fixes</dt><dd>{r.gpsFixRateHz.toFixed(1)} Hz</dd></div>}
        <div><dt>Duration</dt><dd>{fmtDuration(r.durationS)}</dd></div>
        <div><dt>Delimiter</dt><dd>{DELIM[r.delimiter] ?? r.delimiter}</dd></div>
      </dl>
      <div className="chips">
        {r.columns.map((c) => (
          <span key={c.header} className="chip" title={c.header}>{c.field}{c.unit ? ` · ${c.unit}` : ''}</span>
        ))}
        {r.speedDerived && <span className="chip chip--warn">speed derived from GPS</span>}
        {r.ignoredColumns.map((c) => <span key={c} className="chip chip--muted" title="Ignored column">{c}</span>)}
      </div>
      {r.warnings.length > 0 && <ul className="warnings">{r.warnings.map((w, i) => <li key={i}>{w}</li>)}</ul>}
    </div>
  );
}

interface DropProps {
  busy: boolean;
  onFiles: (files: File[]) => void;
  onSample: () => void;
  compact?: boolean;
}

export function DropZone({ busy, onFiles, onSample, compact }: DropProps) {
  const [over, setOver] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  return (
    <div
      className={`dropzone ${over ? 'over' : ''} ${compact ? 'compact' : ''}`}
      onDragOver={(e) => { e.preventDefault(); setOver(true); }}
      onDragLeave={() => setOver(false)}
      onDrop={(e) => {
        e.preventDefault();
        e.stopPropagation();
        setOver(false);
        const files = Array.from(e.dataTransfer.files);
        if (files.length) onFiles(files);
      }}
    >
      <input
        ref={input}
        id="file-input"
        type="file"
        accept=".csv,.txt,.tsv,text/csv,text/plain"
        multiple
        hidden
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          e.target.value = '';
          if (files.length) onFiles(files);
        }}
      />
      {!compact && (
        <svg className="drop-icon" viewBox="0 0 48 48" aria-hidden>
          <path d="M6 34c6-14 14-20 24-20 5 0 9 2 12 5" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
          <path d="M6 34h36" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeDasharray="4 5" />
          <circle cx="30" cy="14" r="3.5" fill="currentColor" />
        </svg>
      )}
      <p className="drop-title">{busy ? 'Reading files…' : 'Drop telemetry CSV files here'}</p>
      <p className="drop-sub">Comma, semicolon, tab or pipe separated · several files at once · nothing leaves your device</p>
      <div className="drop-actions">
        <button type="button" className="btn btn--accent" disabled={busy} onClick={() => input.current?.click()}>Choose files</button>
        <button type="button" className="btn" disabled={busy} onClick={onSample}>Load sample session</button>
      </div>
    </div>
  );
}
