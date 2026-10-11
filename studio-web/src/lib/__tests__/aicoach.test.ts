import { describe, expect, it } from 'vitest';
import { extractNumbers, parseMarkdown, splitBold, verifyNumbers } from '../aicoach';

const facts = {
  referenceLap: { lap: '7', time: '1:32.418' },
  opportunities: [{ corner: 4, gainSeconds: 0.42, brakeLaterByMetres: 18 }, { corner: 9, gainSeconds: 0.31, referenceSpeed: 74, fasterLapSpeed: 79, speedDifference: 5 }],
  lapTimeSpreadSeconds: 1.3,
};

describe('extractNumbers', () => {
  it('reads lap times as seconds', () => {
    expect(extractNumbers('best 1:32.418')[0].value).toBeCloseTo(92.418, 6);
  });
  it('reads signs and decimals', () => {
    expect(extractNumbers('±1.3 s and −0.42')).toEqual([{ value: 1.3, decimals: 1 }, { value: 0.42, decimals: 2 }]);
  });
});

describe('verifyNumbers', () => {
  it('accepts a reply that only uses fact numbers', () => {
    const text = 'Your best was 1:32.418. In corner 4 you can brake 18 m later for 0.42 s. Corner 9: 74 → 79 km/h. Spread ±1.3 s. Do 3 laps.';
    expect(verifyNumbers(text, facts)).toEqual({ ok: true, unknown: [] });
  });
  it('accepts rounded versions of fact numbers', () => {
    expect(verifyNumbers('about 0.4 s in corner 4', facts).ok).toBe(true);
  });
  it('flags invented numbers', () => {
    const v = verifyNumbers('Brake 25 m later to gain 0.8 s, reaching 1:31.900', facts);
    expect(v.ok).toBe(false);
    expect(v.unknown).toEqual(['25', '0.8', '91.900']);
  });
});

describe('markdown', () => {
  it('parses headings, paragraphs and lists', () => {
    const md = '## Summary\nGood day.\nVery good.\n\n## Focus\n- one\n- **two** things\n## Drill\n1. do it';
    expect(parseMarkdown(md)).toEqual([
      { type: 'h', text: 'Summary' },
      { type: 'p', text: 'Good day. Very good.' },
      { type: 'h', text: 'Focus' },
      { type: 'ul', items: ['one', '**two** things'] },
      { type: 'h', text: 'Drill' },
      { type: 'ul', items: ['do it'] },
    ]);
  });
  it('splits bold spans', () => {
    expect(splitBold('a **b** c')).toEqual([{ text: 'a ', bold: false }, { text: 'b', bold: true }, { text: ' c', bold: false }]);
  });
});
