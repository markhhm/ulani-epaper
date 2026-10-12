/**
 * What the app says when something goes wrong, in the language of the page: the cases of cards,
 * photos, files and storage here, Bluetooth and device problems in the words the diagnostics page
 * already uses (spike/errors.ts). The technical message stays English, underneath.
 */

import { CardError } from '../core/cards';
import { CalendarUnavailable } from '../core/defaultCalendar';
import { LibraryError } from '../core/library';
import { PhotoTooLarge, PhotoUnreadable } from '../core/photo';
import { ZipError } from '../core/zip';
import { getLocale, type Locale, t } from '../i18n';
import { type Explained, explainError, technicalDetail } from '../spike/errors';

export function explainAppError(error: unknown, locale: Locale = getLocale()): Explained {
  const say = (key: Parameters<typeof t>[0]): Explained => ({ message: t(key, undefined, locale), detail: technicalDetail(error) });
  if (error instanceof PhotoTooLarge) return say('error.photoTooLarge');
  if (error instanceof PhotoUnreadable) return say('error.photoUnreadable');
  if (error instanceof CalendarUnavailable) return say('calendar.unavailable');
  if (error instanceof ZipError || error instanceof CardError || error instanceof LibraryError || error instanceof SyntaxError) {
    return say('error.badFile');
  }
  if (error instanceof DOMException && error.name !== 'AbortError') return say('error.saveFailed');
  return explainError(error, locale);
}
