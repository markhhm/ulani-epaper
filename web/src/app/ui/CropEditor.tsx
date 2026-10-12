/**
 * Choosing which part of a photo fills the screen (shared/CROP.md): the whole photo with the area
 * outside the frame dimmed. Drag to move, pinch (or the wheel, or the slider) to zoom. What is shown
 * here is a scaled copy for display only; the crop itself is fractions of the full capped photo.
 */

import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { type Crop, defaultCrop, maxZoom, moveCrop, zoomCrop } from '../../core/crop';
import { PointerTracker } from '../../core/gesture';
import { t } from '../../i18n';
import type { LoadedPhoto } from '../photoLoad';

const DISPLAY_LONG_SIDE = 1200;
const same = (a: Crop, b: Crop) => a.every((v, i) => Math.abs(v - (b[i] as number)) < 1e-9);

export function CropEditor(props: { photo: LoadedPhoto; crop: Crop | null; onDone: (crop: Crop | null) => void; onCancel: () => void }) {
  const { photo } = props;
  const W = photo.width;
  const H = photo.height;
  const start = useMemo(() => defaultCrop(W, H), [W, H]);
  const [crop, setCrop] = useState<Crop>(props.crop ?? start);
  const canvas = useRef<HTMLCanvasElement>(null);
  const stage = useRef<HTMLDivElement>(null);
  const tracker = useRef(new PointerTracker());

  // The photo scaled for the screen: display only, the crop never refers to it.
  useEffect(() => {
    const element = canvas.current;
    const context = element?.getContext('2d');
    if (!element || !context) return;
    const scale = Math.min(1, DISPLAY_LONG_SIDE / Math.max(W, H));
    element.width = Math.max(1, Math.round(W * scale));
    element.height = Math.max(1, Math.round(H * scale));
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = 'high';
    context.drawImage(photo.bitmap, 0, 0, element.width, element.height);
  }, [photo, W, H]);

  const rect = () => (stage.current as HTMLDivElement).getBoundingClientRect();
  const level = start[2] / crop[2];
  const top = maxZoom(W, H);

  const onDown = (event: PointerEvent) => {
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    tracker.current.down(event.pointerId, event.clientX, event.clientY);
  };
  const onMove = (event: PointerEvent) => {
    const step = tracker.current.move(event.pointerId, event.clientX, event.clientY);
    if (!step) return;
    const r = rect();
    setCrop((c) => {
      let next = moveCrop(c, W, H, step.dx / r.width, step.dy / r.height);
      if (step.scale !== 1) next = zoomCrop(next, W, H, step.scale, [(step.x - r.left) / r.width, (step.y - r.top) / r.height]);
      return next;
    });
  };
  const onUp = (event: PointerEvent) => tracker.current.up(event.pointerId);
  const onWheel = (event: WheelEvent) => {
    event.preventDefault();
    const r = rect();
    const step = PointerTracker.wheel(event.deltaY, event.clientX, event.clientY);
    setCrop((c) => zoomCrop(c, W, H, step.scale, [(event.clientX - r.left) / r.width, (event.clientY - r.top) / r.height]));
  };
  const onKey = (event: KeyboardEvent) => {
    const step = event.shiftKey ? 0.1 : 0.01;
    const delta: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    const move = delta[event.key];
    if (!move) return;
    event.preventDefault();
    setCrop((c) => moveCrop(c, W, H, move[0], move[1]));
  };

  return (
    <div class="sheet" role="dialog" aria-modal="true" aria-label={t('crop.title')}>
      <header class="sheet-bar">
        <h2>{t('crop.title')}</h2>
      </header>
      <p class="muted">{t('crop.hint')}</p>
      <div class="crop-wrap">
        <div
          class="crop-stage"
          ref={stage}
          tabIndex={0}
          onPointerDown={onDown}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onPointerCancel={onUp}
          onWheel={onWheel}
          onKeyDown={onKey}
        >
          <canvas ref={canvas} class="crop-photo" />
          <div
            class="crop-frame"
            style={{ left: `${crop[0] * 100}%`, top: `${crop[1] * 100}%`, width: `${crop[2] * 100}%`, height: `${crop[3] * 100}%` }}
          />
        </div>
      </div>
      <label class="slider">
        <span>{t('crop.zoom')}</span>
        <input
          type="range"
          min="1"
          max={String(Math.max(top, 1.0001))}
          step="0.01"
          value={String(Math.min(level, top))}
          disabled={top < 1.001}
          onInput={(event) => {
            const target = Number((event.currentTarget as HTMLInputElement).value);
            setCrop((c) => zoomCrop(c, W, H, target / (start[2] / c[2])));
          }}
        />
      </label>
      <div class="actions">
        <button type="button" class="btn btn-secondary" onClick={() => setCrop(start)}>
          {t('crop.reset')}
        </button>
        <button type="button" class="btn btn-secondary" onClick={props.onCancel}>
          {t('crop.cancel')}
        </button>
        <button type="button" class="btn btn-primary" onClick={() => props.onDone(same(crop, start) ? null : crop)}>
          {t('crop.ok')}
        </button>
      </div>
    </div>
  );
}

