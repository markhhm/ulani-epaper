/**
 * The card editor, made for a thumb (like adding text to a story): a live preview in the panel's seven
 * colours, texts that are dragged to move and pinched to resize, colours, outline and alignment, and a
 * photo or colour as the background. Everything it draws is the same drawing the device gets.
 */

import { useEffect, useRef, useState } from 'preact/hooks';
import { addText, moveText, refit, scaleText } from '../../core/cardEdit';
import { ALIGNS, type Card, MAX_SIZE, MAX_TEXT, MAX_TEXTS, MIN_SIZE, normalizeText, type TextBox, textLength } from '../../core/cards';
import type { Crop } from '../../core/crop';
import type { ColourMode } from '../../core/dither';
import type { ColourName } from '../../core/palette';
import { PointerTracker } from '../../core/gesture';
import { COLOUR_MODES, GRAIN_LEVELS } from '../../core/settings';
import { type StringKey, t } from '../../i18n';
import { textRasterizer } from '../canvasText';
import { drawIndices, ditherPhoto, paint } from '../draw';
import type { AppModel, ModelState } from '../model';
import { encodePhoto, type LoadedPhoto, loadPhoto, loadStored } from '../photoLoad';
import { CropEditor } from './CropEditor';
import { saveFile } from './files';
import { FileButton, Swatches, useScreenSize } from './widgets';

const BLANK: Card = { version: 1, id: '', background: { color: 'white' }, texts: [] };

/** The first words of a text, for the list of texts. */
function snippet(text: string): string {
  const line = text.split('\n')[0] ?? '';
  return Array.from(line).slice(0, 10).join('') || '…';
}

export function CardEditor(props: { model: AppModel; state: ModelState; card?: Card | undefined; onClose: () => void }) {
  const { model, state } = props;
  const raster = textRasterizer();
  const initial = props.card ?? BLANK;
  const { colours, grain } = state.settings;

  const [draft, setDraft] = useState<Card>(initial);
  const [selected, setSelected] = useState<number | null>(null);
  const [photo, setPhotoState] = useState<LoadedPhoto | undefined>();
  const [newPhoto, setNewPhoto] = useState(false);
  const [background, setBackground] = useState<Uint8Array | null>(null);
  const [loading, setLoading] = useState(false);
  const [drawing, setDrawing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [cropping, setCropping] = useState(false);
  const [dirty, setDirty] = useState(false);

  const photoRef = useRef<LoadedPhoto | undefined>(undefined);
  const preview = useRef<HTMLCanvasElement>(null);
  const overlay = useRef<HTMLDivElement>(null);
  const textarea = useRef<HTMLTextAreaElement>(null);
  const tracker = useRef(new PointerTracker());
  const touch = useRef({ x: 0, y: 0, moved: false });

  const hasPhoto = 'image' in draft.background;
  const crop: Crop | null = 'image' in draft.background ? draft.background.crop : null;
  const text = selected === null ? undefined : draft.texts[selected];

  /** Keep `next` as the photo (closing the one it replaces). */
  const setPhoto = (next: LoadedPhoto | undefined) => {
    photoRef.current?.bitmap.close();
    photoRef.current = next;
    setPhotoState(next);
  };
  useEffect(() => () => photoRef.current?.bitmap.close(), []);

  const edit = (change: (d: Card) => Card) => {
    setDraft(change);
    setDirty(true);
  };

  // An existing card's stored photo.
  useEffect(() => {
    if (!('image' in initial.background)) return undefined;
    let stop = false;
    setLoading(true);
    (async () => {
      const bytes = await model.background(initial);
      if (!bytes) throw new Error(`the photo of card ${initial.id} is missing`);
      const loaded = await loadStored(bytes);
      if (stop) loaded.bitmap.close();
      else setPhoto(loaded);
    })()
      .catch((error) => model.reportError(error))
      .finally(() => {
        if (!stop) setLoading(false);
      });
    return () => {
      stop = true;
    };
  }, []);

  // The photo cut and dithered, when it, the crop, the colours or the grain changes (the slow part, kept for text edits).
  const cropKey = JSON.stringify(crop);
  useEffect(() => {
    if (!photo || !hasPhoto) {
      setBackground(null);
      return undefined;
    }
    let stop = false;
    setDrawing(true);
    const timer = setTimeout(() => {
      try {
        const indices = ditherPhoto(photo, crop, { colours, grain });
        if (!stop) setBackground(indices);
      } catch (error) {
        model.reportError(error);
      } finally {
        if (!stop) setDrawing(false);
      }
    }, 20);
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, [photo, hasPhoto, cropKey, colours, grain]);

  // The preview: the text drawn crisp over the dithered background, in the panel's colours.
  const resized = useScreenSize(preview);
  useEffect(() => {
    const element = preview.current;
    if (!element) return undefined;
    const frame = requestAnimationFrame(() => paint(element, drawIndices(draft, hasPhoto ? background : null)));
    return () => cancelAnimationFrame(frame);
  }, [draft, background, hasPhoto, resized]);

  // --- Background ---------------------------------------------------------------------

  const pickColour = (colour: ColourName) => {
    setPhoto(undefined);
    setNewPhoto(false);
    edit((d) => ({ ...d, background: { color: colour } }));
  };

  const choosePhoto = async (file: File) => {
    setLoading(true);
    try {
      const loaded = await loadPhoto(file);
      setPhoto(loaded);
      setNewPhoto(true);
      edit((d) => ({ ...d, background: { image: 'image' in d.background ? d.background.image : initial.id ? `${initial.id}.jpg` : 'photo.jpg', crop: null } }));
      setCropping(true);
    } catch (error) {
      model.reportError(error);
    } finally {
      setLoading(false);
    }
  };

  // --- Texts --------------------------------------------------------------------------

  const patch = (index: number, change: Partial<TextBox>) =>
    edit((d) => ({ ...d, texts: d.texts.map((x, k) => (k === index ? refit({ ...x, ...change }, raster) : x)) }));

  const add = () => {
    if (draft.texts.length >= MAX_TEXTS) return;
    const index = draft.texts.length;
    edit((d) => ({ ...d, texts: addText(d.texts, d.background, raster) }));
    setSelected(index);
    setTimeout(() => textarea.current?.focus(), 0);
  };

  const remove = (index: number) => {
    edit((d) => ({ ...d, texts: d.texts.filter((_, k) => k !== index) }));
    setSelected(null);
  };

  // --- Gestures on the preview --------------------------------------------------------

  const onDown = (event: PointerEvent) => {
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    if (!tracker.current.active) {
      const hit = (event.target as HTMLElement).closest<HTMLElement>('[data-text]');
      setSelected(hit ? Number(hit.dataset.text) : null);
      touch.current = { x: event.clientX, y: event.clientY, moved: false };
    }
    tracker.current.down(event.pointerId, event.clientX, event.clientY);
  };

  const onMove = (event: PointerEvent) => {
    const step = tracker.current.move(event.pointerId, event.clientX, event.clientY);
    if (!step || selected === null) return;
    if (Math.hypot(event.clientX - touch.current.x, event.clientY - touch.current.y) > 4) touch.current.moved = true;
    const r = (overlay.current as HTMLDivElement).getBoundingClientRect();
    edit((d) => {
      const current = d.texts[selected];
      if (!current) return d;
      let next = moveText(current, step.dx / r.width, step.dy / r.height);
      if (step.scale !== 1) next = scaleText(next, step.scale, raster);
      return { ...d, texts: d.texts.map((x, k) => (k === selected ? next : x)) };
    });
  };

  const onUp = (event: PointerEvent) => {
    tracker.current.up(event.pointerId);
    if (!tracker.current.active && !touch.current.moved && selected !== null) textarea.current?.focus();
  };

  const onWheel = (event: WheelEvent) => {
    if (selected === null) return;
    event.preventDefault();
    const step = PointerTracker.wheel(event.deltaY, event.clientX, event.clientY);
    edit((d) => ({ ...d, texts: d.texts.map((x, k) => (k === selected ? scaleText(x, step.scale, raster) : x)) }));
  };

  // --- Saving -------------------------------------------------------------------------

  const save = async (show: boolean) => {
    setSaving(true);
    try {
      const texts = draft.texts.filter((x) => normalizeText(x.text) !== ''); // a text left empty is dropped
      const prepared = newPhoto && photo && hasPhoto ? await encodePhoto(photo) : undefined;
      const saved = await model.saveCard({ ...draft, texts }, prepared);
      props.onClose();
      if (show) void model.pushCard(saved);
    } catch (error) {
      model.reportError(error);
      setSaving(false);
    }
  };

  const close = () => {
    if (dirty && !confirm(t('editor.discardConfirm'))) return;
    props.onClose();
  };

  const deleteCard = async () => {
    if (!confirm(t('editor.deleteConfirm'))) return;
    try {
      await model.deleteCard(initial.id);
      props.onClose();
    } catch (error) {
      model.reportError(error);
    }
  };

  const exportCard = async () => {
    try {
      await saveFile(`card-${initial.id}.paperhue-card`, await model.exportCard(initial.id));
    } catch (error) {
      model.reportError(error);
    }
  };

  if (cropping && photo) {
    return (
      <CropEditor
        photo={photo}
        crop={crop}
        onCancel={() => setCropping(false)}
        onDone={(next) => {
          edit((d) => ({ ...d, background: 'image' in d.background ? { image: d.background.image, crop: next } : d.background }));
          setCropping(false);
        }}
      />
    );
  }

  const bgSpec = draft.background;
  const busy = saving || loading;

  return (
    <div class="sheet" role="dialog" aria-modal="true" aria-label={t(props.card ? 'editor.edit' : 'editor.new')}>
      <header class="sheet-bar">
        <h2>{t(props.card ? 'editor.edit' : 'editor.new')}</h2>
        <div class="actions">
          <button type="button" class="btn btn-secondary" onClick={close} disabled={saving}>
            {t('editor.cancel')}
          </button>
          <button type="button" class="btn btn-secondary" onClick={() => void save(false)} disabled={busy}>
            {t('editor.save')}
          </button>
          <button type="button" class="btn btn-primary" onClick={() => void save(true)} disabled={busy}>
            {t('editor.saveShow')}
          </button>
        </div>
      </header>

      <p class="muted small">{t('editor.preview')}</p>
      <div class="preview">
        <canvas ref={preview} class="frame-canvas" width={800} height={480} />
        <div
          class="overlay"
          ref={overlay}
          onPointerDown={onDown}
          onPointerMove={onMove}
          onPointerUp={onUp}
          onPointerCancel={onUp}
          onWheel={onWheel}
        >
          {draft.texts.map((x, i) => (
            <div
              key={i}
              data-text={i}
              class={`tbox${i === selected ? ' on' : ''}`}
              style={{ left: `${x.box[0] * 100}%`, top: `${x.box[1] * 100}%`, width: `${x.box[2] * 100}%`, height: `${x.box[3] * 100}%` }}
            />
          ))}
        </div>
        {(drawing || loading) && <div class="preview-note">{loading ? t('photo.reading') : t('editor.drawing')}</div>}
      </div>
      <p class="muted small">{t('editor.hint')}</p>

      <section class="group">
        <h3>{t('editor.background')}</h3>
        <Swatches label={t('editor.background')} value={'color' in bgSpec ? bgSpec.color : undefined} onPick={pickColour} />
        <div class="row">
          <FileButton label={t('photo.choose')} accept="image/*" disabled={busy} onFile={(f) => void choosePhoto(f)} />
          <FileButton label={t('photo.camera')} accept="image/*" capture="environment" disabled={busy} onFile={(f) => void choosePhoto(f)} />
          {hasPhoto && photo && (
            <button type="button" class="btn btn-secondary" onClick={() => setCropping(true)}>
              {t('photo.crop')}
            </button>
          )}
        </div>
        {hasPhoto && (
          <div class="field">
            <label for="card-colours">{t('colours.label')}</label>
            <select id="card-colours" value={colours} onChange={(e) => void model.setColours((e.currentTarget as HTMLSelectElement).value as ColourMode)}>
              {COLOUR_MODES.map((mode) => (
                <option value={mode}>{t(`colours.${mode}` as StringKey)}</option>
              ))}
            </select>
            <span class="muted small">{t(`colours.${colours}.hint` as StringKey)}</span>
          </div>
        )}
        {hasPhoto && (
          <label class="field">
            <span>{t('grain.label')}</span>
            <select value={String(grain)} onChange={(e) => void model.setGrain(Number((e.currentTarget as HTMLSelectElement).value))}>
              {GRAIN_LEVELS.map((level) => (
                <option value={String(level.strength)}>{t(`grain.${level.key}` as StringKey)}</option>
              ))}
            </select>
          </label>
        )}
      </section>

      <section class="group">
        <div class="row between">
          <h3>{t('editor.text')}</h3>
          <button type="button" class="btn btn-secondary" onClick={add} disabled={draft.texts.length >= MAX_TEXTS}>
            {t('editor.addText')}
          </button>
        </div>
        {draft.texts.length >= MAX_TEXTS && <p class="muted small">{t('editor.maxTexts', { max: MAX_TEXTS })}</p>}
        {draft.texts.length === 0 && <p class="muted">{t('editor.noTexts')}</p>}
        {draft.texts.length > 0 && (
          <div class="chips">
            {draft.texts.map((x, i) => (
              <button type="button" class={`chip${i === selected ? ' on' : ''}`} onClick={() => setSelected(i)}>
                {snippet(x.text)}
              </button>
            ))}
          </div>
        )}

        {text && selected !== null && (
          <div class="text-controls">
            <textarea
              ref={textarea}
              rows={2}
              value={text.text}
              placeholder={t('editor.textPlaceholder')}
              aria-label={t('editor.text')}
              onInput={(e) => patch(selected, { text: Array.from((e.currentTarget as HTMLTextAreaElement).value).slice(0, MAX_TEXT).join('') })}
            />
            <p class="muted small right">{t('editor.counter', { count: textLength(normalizeText(text.text)), max: MAX_TEXT })}</p>

            <div class="field">
              <span>{t('editor.color')}</span>
              <Swatches label={t('editor.color')} value={text.color} onPick={(color) => patch(selected, { color })} />
            </div>
            <label class="field check">
              <input type="checkbox" checked={text.outline} onChange={(e) => patch(selected, { outline: (e.currentTarget as HTMLInputElement).checked })} />
              <span>{t('editor.outline')}</span>
            </label>
            {text.outline && (
              <div class="field">
                <span>{t('editor.outlineColor')}</span>
                <Swatches label={t('editor.outlineColor')} value={text.outline_color} onPick={(outline_color) => patch(selected, { outline_color })} />
              </div>
            )}
            <div class="field">
              <span>{t('editor.align')}</span>
              <div class="segmented" role="radiogroup" aria-label={t('editor.align')}>
                {ALIGNS.map((align) => (
                  <button
                    type="button"
                    role="radio"
                    aria-checked={text.align === align}
                    class={`seg${text.align === align ? ' on' : ''}`}
                    onClick={() => patch(selected, { align })}
                  >
                    {t(`editor.align.${align}` as StringKey)}
                  </button>
                ))}
              </div>
            </div>
            <label class="slider">
              <span>{t('editor.size')}</span>
              <input type="range" min={String(MIN_SIZE)} max={String(MAX_SIZE)} step="1" value={String(text.size)} onInput={(e) => patch(selected, { size: Number((e.currentTarget as HTMLInputElement).value) })} />
              <output>{text.size}</output>
            </label>
            <label class="slider">
              <span>{t('editor.width')}</span>
              <input
                type="range"
                min="5"
                max="100"
                step="1"
                value={String(Math.round(text.box[2] * 100))}
                onInput={(e) => patch(selected, { box: [text.box[0], text.box[1], Number((e.currentTarget as HTMLInputElement).value) / 100, text.box[3]] })}
              />
              <output>{Math.round(text.box[2] * 100)}%</output>
            </label>
            <button type="button" class="btn btn-danger" onClick={() => remove(selected)}>
              {t('editor.removeText')}
            </button>
          </div>
        )}
      </section>

      {props.card && (
        <section class="group row">
          <button type="button" class="btn btn-secondary" onClick={() => void exportCard()}>
            {t('editor.export')}
          </button>
          <button type="button" class="btn btn-danger" onClick={() => void deleteCard()}>
            {t('editor.delete')}
          </button>
        </section>
      )}
    </div>
  );
}
