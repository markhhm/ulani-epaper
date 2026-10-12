/**
 * Errors in plain words for the diagnostics page (Traditional Chinese or
 * English), with the technical message, always in English, kept for the log
 * and for whoever reads it later.
 */

import { TransportError } from '../ble/transport';
import { DeviceError, ProtocolError } from '../core/protocol';
import { getLocale, type Locale, t } from '../i18n';
import { ConnectFailed, DeviceBusy, NoReply, UploadFailed } from '../session/session';

export interface Explained {
  /** What happened and what to try, in the requested language. */
  readonly message: string;
  /** The technical message (English): error names, codes, messages and causes. */
  readonly detail: string;
}

/** An operation that needs a connection was started without one. */
export class NotConnected extends DeviceError {
  override name = 'NotConnected';
}

/**
 * An operation lost its link because the device dropped it while redrawing
 * its screen, as it does: not a failure, and the page reconnects by itself.
 * `cause` is the error the operation got.
 */
export class DroppedWhileRedrawing extends DeviceError {
  override name = 'DroppedWhileRedrawing';
}

function errorName(error: unknown): string {
  if (typeof error === 'object' && error !== null && 'name' in error) return String(error.name);
  return '';
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'object' && error !== null && 'message' in error) return String(error.message);
  return String(error);
}

/** True for the error an AbortSignal rejects with by default. */
export function isAbort(error: unknown): boolean {
  return errorName(error) === 'AbortError';
}

function explainTransport(error: TransportError, locale: Locale): string {
  const text = error.message;
  const location = /location is off/i.test(text);
  const hint = t('error.locationHint', undefined, locale);
  const steps = t('error.repairSteps', undefined, locale);
  switch (error.code) {
    case 'unsupported':
      if (/has no write/i.test(text)) return t('error.noWriteMethod', undefined, locale);
      if (/written with response/i.test(text)) return t('error.withResponseRefused', undefined, locale);
      if (/cannot be read/i.test(text)) return t('error.firmwareUnreadable', undefined, locale);
      // On an open link (not while choosing a device): an operation the device does not permit.
      if (/not permitted|not supported/i.test(text) && !/^choosing a device/i.test(text)) {
        return t('error.notPermitted', undefined, locale);
      }
      return t('bluetoothUnsupported', undefined, locale);
    case 'unavailable':
      if (location) return t('error.locationOff', { hint }, locale);
      return t('error.unavailable', undefined, locale);
    case 'cancelled': {
      const cancelled = t('error.cancelled', undefined, locale);
      return location ? `${cancelled} ${t('error.cancelledEmptyList', { hint }, locale)}` : cancelled;
    }
    case 'notFound': {
      const notFound = t('error.notFound', undefined, locale);
      return location ? `${notFound} ${hint}` : notFound;
    }
    case 'bondLost':
      return t('error.bondLost', { steps }, locale);
    case 'linkLost': {
      const pairingHint = t('connect.pairingHint', undefined, locale);
      if (error.duringPairing) return t('error.linkLostPairing', { hint: pairingHint, steps }, locale);
      if (error.droppedWhileConnecting) return t('error.droppedWhileConnecting', { hint: pairingHint }, locale);
      return t('error.linkLost', undefined, locale);
    }
    case 'timeout':
      return t('error.timeout', { hint: t('error.refreshHint', undefined, locale) }, locale);
  }
}

/** The error in plain words for people (`locale`, default the current one) plus the technical detail. */
export function explainError(error: unknown, locale: Locale = getLocale()): Explained {
  return { message: tidy(plainMessage(error, locale), locale), detail: technicalDetail(error) };
}

/** Chinese sentences need no space between them; English ones get exactly one. */
function tidy(text: string, locale: Locale): string {
  const trimmed = text.trim();
  return locale === 'zh-TW' ? trimmed.replace(/([。：；？）])\s+/g, '$1') : trimmed.replace(/\s{2,}/g, ' ');
}

function plainMessage(error: unknown, locale: Locale): string {
  if (isAbort(error)) return t('error.stopped', undefined, locale);
  if (error instanceof NotConnected) return t('error.notConnected', undefined, locale);
  if (error instanceof DroppedWhileRedrawing) return t('error.droppedWhileRedrawing', undefined, locale);
  if (error instanceof TransportError) return explainTransport(error, locale);
  if (error instanceof NoReply) return t('error.noReply', { hint: t('error.refreshHint', undefined, locale) }, locale);
  if (error instanceof DeviceBusy) return t('error.busy', undefined, locale);
  if (error instanceof UploadFailed) return t('error.uploadRejected', undefined, locale);
  if (error instanceof ProtocolError) return t('error.protocol', undefined, locale);
  if (error instanceof ConnectFailed) {
    const pairingHint = t('connect.pairingHint', undefined, locale);
    if (error.stalePairing) {
      const steps = t('error.repairSteps', undefined, locale);
      return t('error.connectStale', { attempts: error.attempts, hint: pairingHint, steps }, locale);
    }
    let cause = error.cause === undefined ? '' : plainMessage(error.cause, locale);
    // An earlier attempt was dropped: the device may not be in pairing mode.
    if (error.droppedWhileConnecting && !cause.includes(pairingHint)) cause = `${cause} ${pairingHint}`;
    return t('error.connectFailed', { attempts: error.attempts, cause }, locale);
  }
  if (error instanceof DeviceError) return t('error.device', undefined, locale);
  return t('error.unexpected', undefined, locale);
}

/**
 * `Name (code): message`, then `cause: …` for each cause (at most four
 * levels), one per line.
 */
export function technicalDetail(error: unknown): string {
  const lines: string[] = [];
  let current: unknown = error;
  for (let depth = 0; depth < 5 && current !== undefined; depth++) {
    const name = errorName(current) || typeof current;
    const code = current instanceof TransportError ? ` (${current.code})` : '';
    const line = `${name}${code}: ${errorMessage(current)}`;
    lines.push(depth === 0 ? line : `cause: ${line}`);
    current = current instanceof Error ? current.cause : undefined;
  }
  return lines.join('\n');
}
