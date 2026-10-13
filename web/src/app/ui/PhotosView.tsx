/** 照片 / Photos: choose a photo, pick the part that fills the screen, see it in 7 colours, send it to a photo page. */

import { useEffect, useRef, useState } from 'preact/hooks';
import type { Crop } from '../../core/crop';
import type { FitMode } from '../../core/fit';
import { packIndices } from '../../core/frame';
import { suggestedPhotoSlot } from '../../core/pages';
import { USER_SLOTS } from '../../core/protocol';
import { GRAIN_LEVELS } from '../../core/settings';
import { type StringKey, t } from '../../i18n';
import { ditherPhoto } from '../draw';
import type { AppModel, ModelState } from '../model';
import { type LoadedPhoto, loadPhoto } from '../photoLoad';
import { CropEditor } from './CropEditor';
import { FileButton, FrameCanvas } from './widgets';

export function PhotosView(props: { model: AppModel; state: ModelState }) {
  const { model, state } = props;
  const { pages, grain } = state.settings;
  const photoPages = USER_SLOTS.filter((slot) => pages[slot] === 'photo');
  const [chosen, setChosen] = useState<number | undefined>();
  const page = chosen !== undefined && photoPages.includes(chosen) ? chosen : photoPages[0];

  const [photo, setPhotoState] = useState<LoadedPhoto | undefined>();
  const [crop, setCrop] = useState<Crop | null>(null);
  const [mode, setMode] = useState<FitMode>('cover');
  const [indices, setIndices] = useState<Uint8Array | undefined>();
  const [loading, setLoading] = useState(false);
  const [cropping, setCropping] = useState(false);
  const kept = useRef<LoadedPhoto | undefined>(undefined);

  useEffect(() => () => kept.current?.bitmap.close(), []);

  const choose = async (file: File) => {
    setLoading(true);
    try {
      const loaded = await loadPhoto(file);
      kept.current?.bitmap.close();
      kept.current = loaded;
      setPhotoState(loaded);
      setCrop(null); // choosing another photo resets the crop
      setIndices(undefined);
    } catch (error) {
      model.reportError(error);
    } finally {
      setLoading(false);
    }
  };

  // The photo cut from the full image and dithered: the preview and what is sent.
  const cropKey = JSON.stringify(crop);
  useEffect(() => {
    if (!photo) return undefined;
    setIndices(undefined);
    const timer = setTimeout(() => {
      try {
        setIndices(ditherPhoto(photo, crop, grain, mode));
      } catch (error) {
        model.reportError(error);
      }
    }, 20);
    return () => clearTimeout(timer);
  }, [photo, cropKey, grain, mode]);

  if (cropping && photo) {
    return (
      <CropEditor
        photo={photo}
        crop={crop}
        onCancel={() => setCropping(false)}
        onDone={(next) => {
          setCrop(next);
          setCropping(false);
        }}
      />
    );
  }

  const busy = state.job !== undefined;

  return (
    <section aria-labelledby="photos-title">
      <h2 id="photos-title">{t('photos.title')}</h2>
      <p class="muted">{t('photos.intro')}</p>

      {photoPages.length === 0 ? (
        <div class="note-box">
          <p>{t('photos.noPhotoPage')}</p>
          <button type="button" class="btn btn-secondary" onClick={() => void model.setPageKind(suggestedPhotoSlot(pages), 'photo')}>
            {t('photos.makePhotoPage', { page: suggestedPhotoSlot(pages) })}
          </button>
        </div>
      ) : (
        <>
          <div class="field">
            <span>{t('photos.page')}</span>
            <div class="segmented" role="radiogroup" aria-label={t('photos.page')}>
              {photoPages.map((slot) => (
                <button type="button" role="radio" aria-checked={page === slot} class={`seg${page === slot ? ' on' : ''}`} onClick={() => setChosen(slot)}>
                  {t('page.n', { page: slot })}
                </button>
              ))}
            </div>
          </div>
          <div class="row">
            <FileButton label={t('photo.choose')} accept="image/*" disabled={loading || busy} onFile={(f) => void choose(f)} />
            <FileButton label={t('photo.camera')} accept="image/*" capture="environment" disabled={loading || busy} onFile={(f) => void choose(f)} />
          </div>
        </>
      )}

      {loading && <p class="muted">{t('photo.reading')}</p>}

      {photo && (
        <>
          <p class="muted small">{t('photos.preview')}</p>
          <div class="preview">
            {indices ? <FrameCanvas indices={indices} label={t('photos.preview')} /> : <div class="thumb-wait wide" />}
          </div>
          <div class="field">
            <span>{t('photos.mode')}</span>
            <div class="segmented" role="radiogroup" aria-label={t('photos.mode')}>
              <button type="button" role="radio" aria-checked={mode === 'cover'} class={`seg${mode === 'cover' ? ' on' : ''}`} onClick={() => setMode('cover')}>
                {t('photos.fill')}
              </button>
              <button type="button" role="radio" aria-checked={mode === 'contain'} class={`seg${mode === 'contain' ? ' on' : ''}`} onClick={() => setMode('contain')}>
                {t('photos.fit')}
              </button>
            </div>
          </div>
          <div class="row">
            <button type="button" class="btn btn-secondary" disabled={mode !== 'cover'} onClick={() => setCropping(true)}>
              {t('photo.crop')}
            </button>
            <label class="field inline">
              <span>{t('grain.label')}</span>
              <select value={String(grain)} onChange={(e) => void model.setGrain(Number((e.currentTarget as HTMLSelectElement).value))}>
                {GRAIN_LEVELS.map((level) => (
                  <option value={String(level.strength)}>{t(`grain.${level.key}` as StringKey)}</option>
                ))}
              </select>
            </label>
          </div>
          <button
            type="button"
            class="btn btn-primary wide"
            disabled={!indices || page === undefined || busy}
            onClick={() => indices && page !== undefined && void model.sendFrame(page, packIndices(indices))}
          >
            {t('photos.send', { page: page ?? 0 })}
          </button>
        </>
      )}
    </section>
  );
}
