// AI debrief. The rules engine works out every number; Claude only turns those
// facts into plain-language coaching. Uses the driver's own Anthropic key, which
// stays in this browser and is sent only to api.anthropic.com.

import { useEffect, useMemo, useRef, useState } from 'react';
import {
  AI_MODELS, AiError, MODEL_STORAGE, SYSTEM_PROMPT, callClaude, factsMessage, keyIsRemembered,
  parseMarkdown, readStoredKey, splitBold, storeKey, verifyNumbers, type ChatMessage, type Facts,
} from '../lib/aicoach';

interface Props {
  facts: Facts;
  /** Plain rule-based summary, shown when there is no key or the call fails. */
  fallback: string[];
}

interface Turn { role: 'user' | 'assistant'; content: string; unverified?: string[]; shown?: boolean }

function Md({ text }: { text: string }) {
  const inline = (t: string) => splitBold(t).map((p, i) => (p.bold ? <strong key={i}>{p.text}</strong> : <span key={i}>{p.text}</span>));
  return (
    <>
      {parseMarkdown(text).map((b, i) =>
        b.type === 'h' ? <h4 key={i}>{inline(b.text)}</h4>
          : b.type === 'ul' ? <ul key={i}>{b.items.map((it, j) => <li key={j}>{inline(it)}</li>)}</ul>
            : <p key={i}>{inline(b.text)}</p>)}
    </>
  );
}

function errorText(e: unknown): string {
  if (e instanceof AiError) {
    if (e.kind === 'key') return 'Anthropic rejected the key. Check it was copied in full, then paste it again.';
    if (e.kind === 'rate') return 'Too many requests or not enough credit on this key. Wait a minute or top up at console.anthropic.com.';
    if (e.kind === 'network') return 'Could not reach Anthropic. Check your connection and try again.';
    if (e.kind === 'model') return 'That model is not available on your key. Pick the other model and try again.';
    return `Anthropic returned an error: ${e.message}`;
  }
  return e instanceof Error ? e.message : 'Something went wrong.';
}

function readModel(): string {
  try { return localStorage.getItem(MODEL_STORAGE) ?? AI_MODELS[0].id; } catch { return AI_MODELS[0].id; }
}

export function AICoachPanel({ facts, fallback }: Props) {
  const [key, setKey] = useState(readStoredKey);
  const [draft, setDraft] = useState('');
  const [remember, setRemember] = useState(keyIsRemembered);
  const [model, setModel] = useState(readModel);
  const [turns, setTurns] = useState<Turn[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [question, setQuestion] = useState('');
  const abort = useRef<AbortController | null>(null);
  const factsKey = useMemo(() => JSON.stringify(facts), [facts]);

  // New session or different laps → the old debrief no longer applies.
  useEffect(() => { abort.current?.abort(); setTurns([]); setError(null); }, [factsKey]);
  useEffect(() => () => abort.current?.abort(), []);

  const saveKey = () => {
    const k = draft.trim();
    if (!k) return;
    storeKey(k, remember);
    setKey(k); setDraft('');
  };
  const forget = () => { storeKey('', false); setKey(''); setTurns([]); };
  const pickModel = (m: string) => { setModel(m); try { localStorage.setItem(MODEL_STORAGE, m); } catch { /* ignore */ } };

  const ask = async (history: Turn[]) => {
    abort.current?.abort();
    const ctl = new AbortController(); abort.current = ctl;
    setBusy(true); setError(null);
    const messages: ChatMessage[] = [
      { role: 'user', content: factsMessage(facts) },
      ...history.map((t) => ({ role: t.role, content: t.content })),
    ];
    if (!history.length) messages[0] = { role: 'user', content: `${factsMessage(facts)}\n\nGive me my debrief for this session.` };
    try {
      const text = await callClaude(key, model, SYSTEM_PROMPT, messages, ctl.signal);
      const v = verifyNumbers(text, facts);
      setTurns([...history, { role: 'assistant', content: text, unverified: v.ok ? undefined : v.unknown }]);
    } catch (e) {
      if (ctl.signal.aborted) return;
      setError(errorText(e));
    } finally {
      if (abort.current === ctl) setBusy(false);
    }
  };

  const send = () => {
    const q = question.trim();
    if (!q || busy) return;
    setQuestion('');
    const next: Turn[] = [...turns, { role: 'user', content: q }];
    setTurns(next);
    void ask(next);
  };
  const reveal = (i: number) => setTurns((ts) => ts.map((t, j) => (j === i ? { ...t, shown: true } : t)));

  return (
    <section className="card ai-coach">
      <header className="card-head">
        <h2>AI debrief</h2>
        {key && <button type="button" className="link link--danger" onClick={forget}>Forget key</button>}
      </header>

      {!key ? (
        <form className="ai-key" onSubmit={(e) => { e.preventDefault(); saveKey(); }}>
          <p>Get a spoken-style debrief of this session from Claude. Paste your own Anthropic API key. It stays in this browser and is sent only to Anthropic.</p>
          <label htmlFor="ai-key-input">Anthropic API key</label>
          <div className="ai-key-row">
            <input id="ai-key-input" type="password" autoComplete="off" spellCheck={false} placeholder="sk-ant-…" value={draft} onChange={(e) => setDraft(e.target.value)} />
            <button type="submit" className="btn btn--accent" disabled={!draft.trim()}>Use key</button>
          </div>
          <label className="check" htmlFor="ai-remember">
            <input id="ai-remember" type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} />
            Remember on this device
          </label>
          <p className="hint">Get a key at console.anthropic.com → API keys. Without one you still get the rule-based coach below.</p>
        </form>
      ) : (
        <div className="ai-controls">
          <label htmlFor="ai-model">Model</label>
          <select id="ai-model" value={model} onChange={(e) => pickModel(e.target.value)}>
            {AI_MODELS.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
          </select>
          <button type="button" className="btn btn--accent" disabled={busy} onClick={() => { setTurns([]); void ask([]); }}>
            {turns.length ? 'New debrief' : 'Debrief me'}
          </button>
          {busy && <button type="button" className="btn btn--small" onClick={() => { abort.current?.abort(); setBusy(false); }}>Stop</button>}
        </div>
      )}

      {busy && <p className="hint ai-busy" role="status">Claude is reading your session…</p>}
      {error && <p className="notice notice--error" role="alert">{error}</p>}

      {turns.length > 0 && (
        <div className="ai-thread" aria-live="polite">
          {turns.map((t, i) => (
            <div key={i} className={`ai-turn ai-turn--${t.role}`}>
              {t.role === 'user' ? <p className="ai-q">{t.content}</p>
                : t.unverified && !t.shown ? (
                  <div className="caveat">
                    <p>This answer mentions numbers that aren't in your data ({t.unverified.join(', ')}). It may be making things up.</p>
                    <button type="button" className="btn btn--small" onClick={() => reveal(i)}>Show anyway</button>
                    {' '}<button type="button" className="btn btn--small" onClick={() => void ask(turns.slice(0, i))}>Ask again</button>
                  </div>
                ) : <div className="ai-a"><Md text={t.content} /></div>}
            </div>
          ))}
        </div>
      )}

      {key && turns.some((t) => t.role === 'assistant') && (
        <form className="ai-ask" onSubmit={(e) => { e.preventDefault(); send(); }}>
          <label htmlFor="ai-question" className="sr-only">Ask a follow-up</label>
          <input id="ai-question" type="text" placeholder="Ask a follow-up, e.g. “What should I try in turn 3?”" value={question} onChange={(e) => setQuestion(e.target.value)} />
          <button type="submit" className="btn" disabled={busy || !question.trim()}>Ask</button>
        </form>
      )}

      {(!key || error) && fallback.length > 0 && (
        <div className="ai-fallback">
          <h3>Rule-based summary</h3>
          <ul>{fallback.map((f, i) => <li key={i}>{f}</li>)}</ul>
        </div>
      )}
      <p className="footnote">Laptrace works out every number; Claude only explains them. It won't suggest a racing line. Anything it says that isn't in your data gets flagged.</p>
    </section>
  );
}
