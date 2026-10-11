// App header: brand, library toggle, import and theme switch.

interface Props {
  theme: 'light' | 'dark';
  onTheme: () => void;
  onImport: () => void;
  onLibrary: () => void;
  libraryOpen: boolean;
  units: 'kmh' | 'mph';
  onUnits: () => void;
}

export function TopBar({ theme, onTheme, onImport, onLibrary, libraryOpen, units, onUnits }: Props) {
  return (
    <header className="topbar">
      <button type="button" className="icon-btn lib-toggle" onClick={onLibrary} aria-label="Sessions" aria-expanded={libraryOpen}>
        <svg viewBox="0 0 24 24" aria-hidden><path d="M4 6h16M4 12h16M4 18h16" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg>
      </button>
      <div className="brand">
        <svg viewBox="0 0 32 32" className="brand-mark" aria-hidden>
          <rect x="1" y="1" width="30" height="30" rx="7" fill="var(--accent)" />
          <path d="M7 22c3-8 7-12 12-12 3 0 5 1.5 6 3" fill="none" stroke="#fff" strokeWidth="2.6" strokeLinecap="round" />
          <path d="M7 24h18" stroke="#fff" strokeWidth="2" strokeDasharray="2.5 2.5" />
        </svg>
        <span>Laptrace <b>Studio</b></span>
      </div>
      <div className="topbar-actions">
        <button type="button" className="btn btn--accent" onClick={onImport}>Import CSV</button>
        <button
          type="button"
          className="btn units-btn"
          onClick={onUnits}
          aria-label={units === 'kmh' ? 'Show speeds in mph' : 'Show speeds in km/h'}
          title="Speed units"
        >
          {units === 'kmh' ? 'km/h' : 'mph'}
        </button>
        <button
          type="button"
          className="icon-btn"
          onClick={onTheme}
          aria-label={theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'}
          title="Toggle theme"
        >
          {theme === 'dark' ? (
            <svg viewBox="0 0 24 24" aria-hidden><circle cx="12" cy="12" r="4.5" fill="currentColor" /><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></svg>
          ) : (
            <svg viewBox="0 0 24 24" aria-hidden><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5Z" fill="currentColor" /></svg>
          )}
        </button>
      </div>
    </header>
  );
}
