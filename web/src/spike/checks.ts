/**
 * The first step of the diagnostics page: what this browser offers for Web Bluetooth,
 * found without touching a device (no user gesture needed). The write methods are
 * checked again on the device's characteristic once connected
 * (deviceWriteMethodsVerdict), since some browsers expose no class to inspect.
 */

import { WRITE_METHODS, type WriteMethod } from '../ble/webBluetooth';
import { type Localized, message, same } from '../i18n';
import type { CheckId, CheckStatus } from './checklist';

export { WRITE_METHODS, type WriteMethod };

/** What the checks read from the browser; tests pass a made-up one. */
export interface BrowserEnv {
  /** `navigator.bluetooth`. */
  readonly bluetooth: unknown;
  /** `window.isSecureContext`. */
  readonly isSecureContext: boolean | undefined;
  /** `location.protocol`, e.g. `https:`. */
  readonly protocol: string;
  /** The global `BluetoothRemoteGATTCharacteristic` (its prototype holds the write methods). */
  readonly characteristicClass: unknown;
  readonly userAgent: string;
}

/**
 * - `yes` / `no`: what getAvailability() resolved to.
 * - `missing`: the browser has no getAvailability().
 * - `error` / `timeout`: it failed, or did not answer in time.
 */
export type Availability = 'yes' | 'no' | 'missing' | 'error' | 'timeout';

export interface BrowserReport {
  /** `navigator.bluetooth` exists and has requestDevice(). */
  readonly webBluetooth: boolean;
  readonly availability: Availability;
  /** Why getAvailability() failed, when it did. */
  readonly availabilityError?: string;
  readonly secureContext: boolean | undefined;
  readonly protocol: string;
  /**
   * Each write method on BluetoothRemoteGATTCharacteristic.prototype;
   * undefined without that global (Bluefy has none, yet its characteristics
   * have the methods: connecting tells).
   */
  readonly writeMethods: Readonly<Record<WriteMethod, boolean>> | undefined;
  readonly userAgent: string;
}

/** The real browser's values. */
export function browserEnv(): BrowserEnv {
  const scope = globalThis as unknown as {
    navigator?: { bluetooth?: unknown; userAgent?: string };
    isSecureContext?: boolean;
    location?: { protocol?: string };
    BluetoothRemoteGATTCharacteristic?: unknown;
  };
  return {
    bluetooth: scope.navigator?.bluetooth,
    isSecureContext: scope.isSecureContext,
    protocol: scope.location?.protocol ?? '',
    characteristicClass: scope.BluetoothRemoteGATTCharacteristic,
    userAgent: scope.navigator?.userAgent ?? '',
  };
}

function hasMethod(target: unknown, name: string): boolean {
  if ((typeof target !== 'object' && typeof target !== 'function') || target === null) return false;
  return typeof (target as Record<string, unknown>)[name] === 'function';
}

/** Ask getAvailability(), giving up after `timeoutMs`. */
async function availabilityOf(
  bluetooth: unknown,
  timeoutMs: number,
): Promise<{ availability: Availability; error?: string }> {
  if (!hasMethod(bluetooth, 'getAvailability')) return { availability: 'missing' };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<'timeout'>((resolve) => {
    timer = setTimeout(() => resolve('timeout'), timeoutMs);
  });
  try {
    const answer = await Promise.race([
      (bluetooth as { getAvailability(): Promise<boolean> }).getAvailability(),
      timeout,
    ]);
    if (answer === 'timeout') return { availability: 'timeout' };
    return { availability: answer ? 'yes' : 'no' };
  } catch (error) {
    return { availability: 'error', error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) };
  } finally {
    clearTimeout(timer);
  }
}

/** Inspect `env`; never rejects. */
export async function inspectBrowser(env: BrowserEnv = browserEnv(), timeoutMs = 3_000): Promise<BrowserReport> {
  const webBluetooth = hasMethod(env.bluetooth, 'requestDevice');
  const { availability, error } = await availabilityOf(env.bluetooth, timeoutMs);
  const owner = env.characteristicClass;
  const prototype =
    (typeof owner === 'function' || typeof owner === 'object') && owner !== null
      ? (owner as { prototype?: unknown }).prototype
      : undefined;
  const writeMethods =
    prototype === undefined || prototype === null
      ? undefined
      : (Object.fromEntries(WRITE_METHODS.map((name) => [name, hasMethod(prototype, name)])) as Record<
          WriteMethod,
          boolean
        >);
  return {
    webBluetooth,
    availability,
    ...(error === undefined ? {} : { availabilityError: error }),
    secureContext: env.isSecureContext,
    protocol: env.protocol,
    writeMethods,
    userAgent: env.userAgent,
  };
}

export interface Verdict {
  readonly status: CheckStatus;
  readonly note: Localized;
}

/** The checklist entries step 1 decides. */
export type BrowserCheckId = Extract<CheckId, 'webBluetooth' | 'availability' | 'secureContext' | 'writeMethods'>;

/** PASS / FAIL / WARN for each browser check, with a short note. */
export function browserVerdicts(report: BrowserReport): Record<BrowserCheckId, Verdict> {
  return {
    webBluetooth: report.webBluetooth
      ? { status: 'pass', note: same('navigator.bluetooth') }
      : { status: 'fail', note: message('verdict.noBluetooth') },
    availability: availabilityVerdict(report),
    secureContext:
      report.secureContext === true
        ? { status: 'pass', note: same(report.protocol) }
        : report.secureContext === false
          ? { status: 'fail', note: message('verdict.insecure', { protocol: report.protocol || '?' }) }
          : { status: 'warn', note: message('verdict.cannotTell') },
    writeMethods: writeMethodsVerdict(report.writeMethods),
  };
}

function availabilityVerdict(report: BrowserReport): Verdict {
  switch (report.availability) {
    case 'yes':
      return { status: 'pass', note: same('getAvailability() = true') };
    case 'no':
      return { status: 'fail', note: message('verdict.availabilityOff') };
    case 'missing':
      return { status: 'warn', note: message('verdict.availabilityMissing') };
    case 'timeout':
      return { status: 'warn', note: message('verdict.availabilityTimeout') };
    case 'error':
      return { status: 'warn', note: message('verdict.availabilityError', { error: report.availabilityError ?? '' }) };
  }
}

function writeMethodsVerdict(methods: BrowserReport['writeMethods']): Verdict {
  if (!methods) return { status: 'info', note: message('verdict.noCharacteristic') };
  return methodsVerdict(methods, (list) => same(list));
}

/**
 * The write methods check from the device's image characteristic, once
 * connected: what uploads actually use, so it replaces the browser's answer.
 */
export function deviceWriteMethodsVerdict(methods: Readonly<Record<WriteMethod, boolean>>): Verdict {
  return methodsVerdict(methods, (list) => message('verdict.deviceMethods', { methods: list }));
}

function methodsVerdict(methods: Readonly<Record<WriteMethod, boolean>>, passNote: (list: string) => Localized): Verdict {
  const present = WRITE_METHODS.filter((name) => methods[name]);
  const list = present.join(', ');
  if (methods.writeValueWithoutResponse) return { status: 'pass', note: passNote(list) };
  if (present.length > 0) return { status: 'warn', note: message('verdict.noWithoutResponse', { methods: list }) };
  return { status: 'fail', note: message('value.none') };
}

/** `writeValueWithoutResponse=yes, writeValueWithResponse=no, …`, for the log. */
export function describeWriteMethods(methods: Readonly<Record<WriteMethod, boolean>>): string {
  return WRITE_METHODS.map((name) => `${name}=${methods[name] ? 'yes' : 'no'}`).join(', ');
}
