/** The photo behind a calendar page, or of a photo page: choose or take one, pick the part that fills the screen (a photo page can show it whole instead), or take it away. */

import { useEffect, useRef, useState } from 'preact/hooks';
import type { Crop } from '../../core/crop';
import { t } from '../../i18n';
import type { AppModel } from '../model';
import { encodePhoto, type LoadedPhoto, loadPhoto, loadStored } from '../photoLoad';
import { CropEditor } from './CropEditor';
import { FileButton } from './widgets';

/** The photo being cropped: a new one (it is stored when the crop is confirmed) or the one already stored. */
interface Editing {
  photo: LoadedPhoto;
  fresh: boolean;
}

export function BackgroundControls(props: {
  model: AppModel;
  slot: number;
  /** The crop of the stored photo, or null, and how a photo page fits it; undefined when the page has no photo. */
  stored: { crop: Crop | null; fit?: 'contain' } | undefined;
  /** The page is a photo page: the photo is what it shows, not a background. */
  photoPage?: boolean;
  /** The stored photo changed (even when the settings look the same): draw the page again. */
  onChange: () => void;
}) {
  const { model, slot, stored } = props;
  const [editing, setEditing] = useState<Editing | undefined>();
  const [working, setWorking] = useState(false);
  const open = useRef<LoadedPhoto | undefined>(undefined);

  useEffect(() => () => open.current?.bitmap.close(), []);

  const edit = (photo: LoadedPhoto, fresh: boolean) => {
    open.current?.bitmap.close();
    open.current = photo;
    setEditing({ photo, fresh });
  };

  const close = () => {
    open.current?.bitmap.close();
    open.current = undefined;
    setEditing(undefined);
  };

  /** Run `work` with the buttons off; a failure is shown to the user. */
  const run = async (work: () => Promise<void>) => {
    setWorking(true);
    try {
      await work();
    } catch (error) {
      model.reportError(error);
    } finally {
      setWorking(false);
    }
  };

  const choose = (file: File) => run(async () => edit(await loadPhoto(file), true));

  const recrop = () =>
    run(async () => {
      const bytes = await model.pageBackground(slot);
      if (!bytes) throw new Error(`the photo of page ${slot} is missing`);
      edit(await loadStored(bytes), false);
    });

  const done = (crop: Crop | null) =>
    run(async () => {
      if (!editing) return;
      await model.setPageBackground(slot, crop, editing.fresh ? await encodePhoto(editing.photo) : undefined);
      close();
      props.onChange();
    });

  const remove = () =>
    run(async () => {
      await model.clearPageBackground(slot);
      props.onChange();
    });

  if (editing) return <CropEditor photo={editing.photo} crop={editing.fresh ? null : (stored?.crop ?? null)} onCancel={close} onDone={(crop) => void done(crop)} />;

  const fit = stored?.fit ?? 'cover';
  return (
    <div class="group">
      <h3>{t(props.photoPage ? 'pages.photo.title' : 'pages.bg.title')}</h3>
      <p class="muted small">{t(props.photoPage ? 'pages.photo.hint' : 'pages.bg.hint')}</p>
      <div class="row">
        <FileButton label={t('photo.choose')} accept="image/*" disabled={working} onFile={(f) => void choose(f)} />
        <FileButton label={t('photo.camera')} accept="image/*" capture="environment" disabled={working} onFile={(f) => void choose(f)} />
        {stored && (
          <>
            <button type="button" class="btn btn-secondary" disabled={working || (props.photoPage && fit === 'contain')} onClick={() => void recrop()}>
              {t('photo.crop')}
            </button>
            <button type="button" class="btn btn-secondary" disabled={working} onClick={() => void remove()}>
              {t('pages.bg.remove')}
            </button>
          </>
        )}
      </div>
      {props.photoPage && stored && (
        <div class="field">
          <span>{t('pages.photo.mode')}</span>
          <div class="segmented" role="radiogroup" aria-label={t('pages.photo.mode')}>
            {(['cover', 'contain'] as const).map((choice) => (
              <button type="button" role="radio" aria-checked={fit === choice} class={`seg${fit === choice ? ' on' : ''}`} disabled={working} onClick={() => void model.setPhotoFit(slot, choice)}>
                {t(choice === 'cover' ? 'pages.photo.fill' : 'pages.photo.fit')}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
