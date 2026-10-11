// Friction-circle scatter: lateral g (x, right +) vs longitudinal g (y, accel +).

import { useEffect, useRef } from 'react';
import { cursor } from '../state/cursor';
import { sampleAt } from '../lib/alignment';
import { speedColor } from '../lib/format';
import type { Workspace } from '../lib/workspace';
import type { LapData } from '../lib/types';

interface Props {
  lap: LapData;
  ws: Workspace | null;
  theme: string;
}

export function GGDiagram({ lap, ws, theme }: Props) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const base = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const cv = canvas.current;
    if (!cv) return;
    const draw = () => {
      const size = cv.clientWidth;
      const dpr = window.devicePixelRatio || 1;
      if (cv.width !== Math.round(size * dpr)) {
        cv.width = Math.round(size * dpr);
        cv.height = Math.round(size * dpr);
        base.current = null;
      }
      const ctx = cv.getContext('2d');
      if (!ctx) return;
      const styles = getComputedStyle(document.documentElement);
      const fg = styles.getPropertyValue('--muted').trim() || '#888';
      const grid = styles.getPropertyValue('--grid').trim() || 'rgba(128,128,128,.2)';
      const gl = lap.gLong;
      const gt = lap.gLat;
      let maxG = 1;
      if (gl && gt) for (let i = 0; i < gl.length; i++) maxG = Math.max(maxG, Math.abs(gl[i]), Math.abs(gt[i]));
      maxG = Math.min(3, Math.ceil(maxG * 2) / 2 + 0.25);
      const W = cv.width;
      const c = W / 2;
      const r = (W / 2) * 0.92;
      const px = (g: number) => (g / maxG) * r;

      if (!base.current) {
        const off = document.createElement('canvas');
        off.width = W;
        off.height = W;
        const o = off.getContext('2d')!;
        o.strokeStyle = grid;
        o.lineWidth = dpr;
        o.fillStyle = fg;
        o.font = `${10 * dpr}px system-ui, sans-serif`;
        for (const g of [0.5, 1, 1.5, 2, 2.5]) {
          if (g > maxG) break;
          o.beginPath();
          o.arc(c, c, px(g), 0, Math.PI * 2);
          o.stroke();
          o.fillText(`${g}g`, c + px(g) * 0.71 + 2 * dpr, c - px(g) * 0.71);
        }
        o.beginPath();
        o.moveTo(c - r, c); o.lineTo(c + r, c);
        o.moveTo(c, c - r); o.lineTo(c, c + r);
        o.stroke();
        o.fillText('Accel', c + 4 * dpr, 12 * dpr);
        o.fillText('Brake', c + 4 * dpr, W - 4 * dpr);
        o.fillText('Right', W - 30 * dpr, c - 4 * dpr);
        o.fillText('Left', 4 * dpr, c - 4 * dpr);
        if (gl && gt) {
          const step = Math.max(1, Math.floor(gl.length / 4000));
          for (let i = 0; i < gl.length; i += step) {
            o.fillStyle = speedColor(lap.speed[i], lap.minSpeed, lap.maxSpeed);
            o.globalAlpha = 0.75;
            o.beginPath();
            o.arc(c + px(gt[i]), c - px(gl[i]), 1.8 * dpr, 0, Math.PI * 2);
            o.fill();
          }
          o.globalAlpha = 1;
        }
        base.current = off;
      }
      ctx.clearRect(0, 0, W, W);
      ctx.drawImage(base.current, 0, 0);

      // Cursor dot.
      const cur = cursor.get();
      const a = ws?.aligned.get(lap.key);
      if (cur.s != null && a?.gLong && a.gLat) {
        const y = sampleAt(a.gLong, cur.s);
        const x = sampleAt(a.gLat, cur.s);
        if (Number.isFinite(x) && Number.isFinite(y)) {
          ctx.beginPath();
          ctx.arc(c + px(x), c - px(y), 6 * dpr, 0, Math.PI * 2);
          ctx.fillStyle = '#fff';
          ctx.fill();
          ctx.lineWidth = 3 * dpr;
          ctx.strokeStyle = '#ff2d2d';
          ctx.stroke();
        }
      }
    };
    base.current = null;
    draw();
    const unsub = cursor.subscribe(draw);
    const ro = new ResizeObserver(draw);
    ro.observe(cv);
    return () => { unsub(); ro.disconnect(); };
  }, [lap, ws, theme]);

  return (
    <section className="card gg">
      <header className="card-head"><h2>G-G diagram</h2><span className="hint">Lap {lap.label} · coloured by speed</span></header>
      <canvas ref={canvas} className="gg-canvas" aria-label="G-G diagram of lateral versus longitudinal acceleration" />
    </section>
  );
}
