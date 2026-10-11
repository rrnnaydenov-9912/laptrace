// Next-session goal: how you did on the saved goal, and what to work on next time.

import { fmtGoalValue, goalCopy, metricName, type Goal, type GoalProgress } from '../lib/insights';

interface Props {
  trackName: string | null;
  saved: Goal | null;
  progress: GoalProgress | null;
  next: Goal | null;
  onSave: (g: Goal) => void;
  onClear: () => void;
}

export function GoalCard({ trackName, saved, progress, next, onSave, onClear }: Props) {
  const nextCopy = next ? goalCopy(next) : null;
  const sameAsSaved = !!(saved && next && saved.skill === next.skill && saved.corner === next.corner && saved.target === next.target);
  return (
    <section className="card goal">
      <header className="card-head"><h2>Goal</h2><span className="hint">{trackName ?? 'Unknown track'}</span></header>
      {!trackName && <p className="empty">Goals are saved per track. Set a start/finish line so this track can be recognised next time.</p>}
      {saved && (
        <div className="goal-block">
          <h3>Your goal for this session</h3>
          <p className="goal-title">{goalCopy(saved).title}</p>
          {progress && (progress.note ? <p className="hint">{progress.note}</p> : (
            <>
              <p className={`goal-result ${progress.achieved ? 'pos' : ''}`}>
                <span className={`tag ${progress.achieved ? 'tag--best' : 'tag--warn'}`}>{progress.achieved ? 'Achieved' : 'Not yet'}</span>
                {' '}{progress.hits} of {progress.laps} lap{progress.laps === 1 ? '' : 's'} hit the target.
              </p>
              <dl className="goal-figs">
                <div><dt>Started at</dt><dd>{fmtGoalValue(saved.skill, saved.baseline)}</dd></div>
                <div><dt>Target</dt><dd>{fmtGoalValue(saved.skill, saved.target)}</dd></div>
                <div><dt>Typical today</dt><dd>{fmtGoalValue(saved.skill, progress.median)}</dd></div>
                <div><dt>Best today</dt><dd>{fmtGoalValue(saved.skill, progress.best)}</dd></div>
              </dl>
              <p className="footnote">Measured as {metricName(saved.skill)}.</p>
            </>
          ))}
          <button type="button" className="link link--danger" onClick={onClear}>Clear goal</button>
        </div>
      )}
      {next && nextCopy && trackName && (
        <div className="goal-block">
          <h3>Next time</h3>
          <p className="goal-title">{nextCopy.title}</p>
          <p>{nextCopy.why}</p>
          <p className="hint">{nextCopy.how}</p>
          {sameAsSaved ? <span className="tag tag--ok">Saved</span> : (
            <button type="button" className="btn btn--small btn--accent" onClick={() => onSave(next)}>
              {saved ? 'Replace goal with this' : 'Save as my goal'}
            </button>
          )}
        </div>
      )}
      {!next && trackName && !saved && <p className="empty">Drive at least three timed laps to get a goal.</p>}
    </section>
  );
}
