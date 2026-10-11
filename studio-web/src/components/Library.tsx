// Session library: list, open, rename, delete (with inline confirmation).

import { useState } from 'react';
import { fmtDate, fmtLap } from '../lib/format';
import type { SessionSummary } from '../lib/types';

interface Props {
  summaries: SessionSummary[];
  currentId: string | null;
  onOpen: (id: string) => void;
  onRename: (id: string, name: string) => void;
  onDelete: (id: string) => void;
  onImport: () => void;
}

function Row({ s, current, onOpen, onRename, onDelete }: {
  s: SessionSummary; current: boolean; onOpen: () => void; onRename: (n: string) => void; onDelete: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [name, setName] = useState(s.name);

  const commit = () => {
    const n = name.trim();
    if (n && n !== s.name) onRename(n);
    else setName(s.name);
    setEditing(false);
  };

  return (
    <li className={`lib-item ${current ? 'current' : ''}`}>
      {editing ? (
        <form onSubmit={(e) => { e.preventDefault(); commit(); }}>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            onBlur={commit}
            onKeyDown={(e) => { if (e.key === 'Escape') { setName(s.name); setEditing(false); } }}
            aria-label="Session name"
          />
        </form>
      ) : (
        <button type="button" className="lib-item-btn" onClick={onOpen}>
          <span className="lib-name">{s.name}</span>
          <span className="lib-meta">{s.trackName ?? 'Unknown track'} · {fmtDate(s.date)}</span>
          <span className="lib-stats">
            <b>{fmtLap(s.bestLap)}</b>
            <span>{s.timedLaps} lap{s.timedLaps === 1 ? '' : 's'}</span>
          </span>
        </button>
      )}
      {confirming ? (
        <div className="lib-confirm">
          <span>Delete this session?</span>
          <button type="button" className="btn btn--small btn--danger" onClick={onDelete}>Delete</button>
          <button type="button" className="btn btn--small" onClick={() => setConfirming(false)}>Keep</button>
        </div>
      ) : (
        !editing && (
          <div className="lib-actions">
            <button type="button" className="link" onClick={() => { setName(s.name); setEditing(true); }}>Rename</button>
            <button type="button" className="link link--danger" onClick={() => setConfirming(true)}>Delete</button>
          </div>
        )
      )}
    </li>
  );
}

export function Library({ summaries, currentId, onOpen, onRename, onDelete, onImport }: Props) {
  const sorted = [...summaries].sort((a, b) => (b.date ?? b.importedAt).localeCompare(a.date ?? a.importedAt));
  return (
    <div className="library">
      <div className="lib-head">
        <h2>Sessions</h2>
        <button type="button" className="btn btn--small btn--accent" onClick={onImport}>+ Import</button>
      </div>
      {sorted.length === 0 ? (
        <p className="empty">No sessions yet. Import a CSV to start.</p>
      ) : (
        <ul>
          {sorted.map((s) => (
            <Row
              key={s.id}
              s={s}
              current={s.id === currentId}
              onOpen={() => onOpen(s.id)}
              onRename={(n) => onRename(s.id, n)}
              onDelete={() => onDelete(s.id)}
            />
          ))}
        </ul>
      )}
    </div>
  );
}
