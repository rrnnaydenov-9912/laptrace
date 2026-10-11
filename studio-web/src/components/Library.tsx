// Session library: search, filter, favourite, open, rename, delete (with inline confirmation).

import { useMemo, useState } from 'react';
import { fmtDate, fmtDist, fmtDuration, fmtLap } from '../lib/format';
import type { SessionSummary } from '../lib/types';

interface Props {
  summaries: SessionSummary[];
  currentId: string | null;
  onOpen: (id: string) => void;
  onRename: (id: string, name: string) => void;
  onDelete: (id: string) => void;
  onFavorite: (id: string, favorite: boolean) => void;
  onImport: () => void;
}

const ALL = '__all';
const DRIVES = '__drives';
const FAVS = '__favs';

function Row({ s, current, onOpen, onRename, onDelete, onFavorite }: {
  s: SessionSummary; current: boolean; onOpen: () => void; onRename: (n: string) => void; onDelete: () => void;
  onFavorite: () => void;
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
          <span className="lib-name">
            {s.drive && <span className="badge badge--drive">Drive</span>}
            {s.name}
          </span>
          <span className="lib-meta">{s.drive ? 'Road drive' : s.trackName ?? 'Unknown track'} · {fmtDate(s.date)}</span>
          {s.drive ? (
            <span className="lib-stats">
              <b>{s.distance != null ? fmtDist(s.distance) : '—'}</b>
              <span>{fmtDuration(s.durationS)}</span>
            </span>
          ) : (
            <span className="lib-stats">
              <b>{fmtLap(s.bestLap)}</b>
              <span>{s.timedLaps} lap{s.timedLaps === 1 ? '' : 's'}</span>
            </span>
          )}
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
            <button
              type="button"
              className={`link fav ${s.favorite ? 'on' : ''}`}
              onClick={onFavorite}
              aria-pressed={!!s.favorite}
              aria-label={s.favorite ? 'Remove from favourites' : 'Add to favourites'}
            >
              {s.favorite ? '★' : '☆'}
            </button>
            <button type="button" className="link" onClick={() => { setName(s.name); setEditing(true); }}>Rename</button>
            <button type="button" className="link link--danger" onClick={() => setConfirming(true)}>Delete</button>
          </div>
        )
      )}
    </li>
  );
}

export function Library({ summaries, currentId, onOpen, onRename, onDelete, onFavorite, onImport }: Props) {
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState(ALL);

  const trackNames = useMemo(
    () => [...new Set(summaries.filter((s) => !s.drive && s.trackName).map((s) => s.trackName!))].sort(),
    [summaries],
  );
  const hasDrives = summaries.some((s) => s.drive);

  const q = query.trim().toLowerCase();
  const sorted = summaries
    .filter((s) => {
      if (filter === DRIVES && !s.drive) return false;
      if (filter === FAVS && !s.favorite) return false;
      if (filter !== ALL && filter !== DRIVES && filter !== FAVS && s.trackName !== filter) return false;
      if (!q) return true;
      return [s.name, s.trackName ?? '', s.fileName, fmtDate(s.date)].some((x) => x.toLowerCase().includes(q));
    })
    .sort((a, b) => (b.date ?? b.importedAt).localeCompare(a.date ?? a.importedAt));

  return (
    <div className="library">
      <div className="lib-head">
        <h2>Sessions</h2>
        <button type="button" className="btn btn--small btn--accent" onClick={onImport}>+ Import</button>
      </div>
      {summaries.length > 0 && (
        <div className="lib-filters">
          <input
            id="lib-search"
            type="search"
            placeholder="Search sessions"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search sessions"
          />
          <select id="lib-filter" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Filter sessions">
            <option value={ALL}>All sessions</option>
            <option value={FAVS}>Favourites</option>
            {hasDrives && <option value={DRIVES}>Road drives</option>}
            {trackNames.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
      )}
      {summaries.length === 0 ? (
        <p className="empty">No sessions yet. Import a CSV to start.</p>
      ) : sorted.length === 0 ? (
        <p className="empty">No sessions match.</p>
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
              onFavorite={() => onFavorite(s.id, !s.favorite)}
            />
          ))}
        </ul>
      )}
    </div>
  );
}
