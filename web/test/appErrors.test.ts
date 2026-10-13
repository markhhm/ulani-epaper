import { describe, expect, it } from 'vitest';
import { explainAppError } from '../src/app/errors';
import { CardError } from '../src/core/cards';
import { LibraryError } from '../src/core/library';
import { PhotoTooLarge, PhotoUnreadable } from '../src/core/photo';
import { ZipError } from '../src/core/zip';
import { TransportError } from '../src/ble/transport';
import { t } from '../src/i18n';

describe('what the app says when something goes wrong', () => {
  it('names the 50 megapixel limit, not the size of the photo', () => {
    expect(explainAppError(new PhotoTooLarge(), 'zh-TW').message).toBe('照片超過 5000 萬像素的上限，請先縮小再選。');
    expect(explainAppError(new PhotoTooLarge(), 'en').message).toBe('This photo is over the 50-megapixel limit. Shrink it, then choose it again.');
  });

  it('says a photo cannot be opened', () => {
    expect(explainAppError(new PhotoUnreadable(), 'en').message).toBe(t('error.photoUnreadable', undefined, 'en'));
  });

  it('says a card file or backup is not usable, whichever check refused it', () => {
    for (const error of [new ZipError('not a zip'), new CardError('bad card'), new LibraryError('no card'), new SyntaxError('JSON')]) {
      expect(explainAppError(error, 'zh-TW').message).toBe(t('error.badFile', undefined, 'zh-TW'));
    }
  });

  it('says the browser could not save, for what IndexedDB throws', () => {
    expect(explainAppError(new DOMException('full', 'QuotaExceededError'), 'en').message).toBe(t('error.saveFailed', undefined, 'en'));
  });

  it('keeps the technical detail, in English, underneath', () => {
    expect(explainAppError(new ZipError('this is not a zip file'), 'zh-TW').detail).toBe('ZipError: this is not a zip file');
  });

  it('leaves Bluetooth and device problems to the explanations the diagnostics page uses', () => {
    const error = new TransportError('notFound', 'no device');
    expect(explainAppError(error, 'en').message).toContain('No device found');
    expect(explainAppError(new DOMException('stopped', 'AbortError'), 'en').message).toBe('Stopped.');
  });
});
