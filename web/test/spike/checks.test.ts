import { describe, expect, it } from 'vitest';
import { message } from '../../src/i18n';
import {
  type BrowserEnv,
  browserVerdicts,
  describeWriteMethods,
  deviceWriteMethodsVerdict,
  inspectBrowser,
} from '../../src/spike/checks';

class FullCharacteristic {
  writeValue(): void {}
  writeValueWithResponse(): void {}
  writeValueWithoutResponse(): void {}
}

class OldCharacteristic {
  writeValue(): void {}
}

function env(overrides: Partial<BrowserEnv> = {}): BrowserEnv {
  return {
    bluetooth: { requestDevice: () => Promise.reject(new Error('not in tests')), getAvailability: async () => true },
    isSecureContext: true,
    protocol: 'https:',
    characteristicClass: FullCharacteristic,
    userAgent: 'Test/1.0',
    ...overrides,
  };
}

describe('inspectBrowser', () => {
  it('reports a browser with everything', async () => {
    const report = await inspectBrowser(env());
    expect(report).toEqual({
      webBluetooth: true,
      availability: 'yes',
      secureContext: true,
      protocol: 'https:',
      writeMethods: { writeValueWithoutResponse: true, writeValueWithResponse: true, writeValue: true },
      userAgent: 'Test/1.0',
    });
    const verdicts = browserVerdicts(report);
    expect(Object.values(verdicts).map((verdict) => verdict.status)).toEqual(['pass', 'pass', 'pass', 'pass']);
  });

  it('reports a browser without Web Bluetooth', async () => {
    const report = await inspectBrowser(
      env({ bluetooth: undefined, isSecureContext: false, protocol: 'http:', characteristicClass: undefined }),
    );
    expect(report).toMatchObject({ webBluetooth: false, availability: 'missing', secureContext: false });
    expect(report.writeMethods).toBeUndefined();
    const verdicts = browserVerdicts(report);
    expect(verdicts.webBluetooth.status).toBe('fail');
    expect(verdicts.availability.status).toBe('warn');
    expect(verdicts.secureContext).toEqual({ status: 'fail', note: message('verdict.insecure', { protocol: 'http:' }) });
    expect(verdicts.secureContext.note).toEqual({ 'zh-TW': '不是安全連線 (http:)', en: 'not a secure context (http:)' });
    // Without the class there is nothing to inspect yet: connecting decides (INFO, not a warning).
    expect(verdicts.writeMethods).toEqual({ status: 'info', note: message('verdict.noCharacteristic') });
  });

  it('tells Bluetooth that is off from a failing or silent getAvailability', async () => {
    const off = await inspectBrowser(env({ bluetooth: { requestDevice() {}, getAvailability: async () => false } }));
    expect(off.availability).toBe('no');
    expect(browserVerdicts(off).availability.status).toBe('fail');

    const failing = await inspectBrowser(
      env({
        bluetooth: {
          requestDevice() {},
          getAvailability: () => Promise.reject(new DOMException('blocked', 'SecurityError')),
        },
      }),
    );
    expect(failing).toMatchObject({ availability: 'error', availabilityError: 'SecurityError: blocked' });
    expect(browserVerdicts(failing).availability.status).toBe('warn');

    const silent = await inspectBrowser(
      env({ bluetooth: { requestDevice() {}, getAvailability: () => new Promise(() => undefined) } }),
      5,
    );
    expect(silent.availability).toBe('timeout');
  });

  it('warns when only writeValue exists and fails when no write method does', async () => {
    const old = browserVerdicts(await inspectBrowser(env({ characteristicClass: OldCharacteristic })));
    expect(old.writeMethods.status).toBe('warn');
    expect(old.writeMethods.note['zh-TW']).toContain('writeValue');
    expect(old.writeMethods.note.en).toContain('"auto" uses another method');
    const none = browserVerdicts(await inspectBrowser(env({ characteristicClass: class {} })));
    expect(none.writeMethods.status).toBe('fail');
  });

  it('cannot tell the secure context when the browser does not say', async () => {
    const report = await inspectBrowser(env({ isSecureContext: undefined }));
    expect(browserVerdicts(report).secureContext.status).toBe('warn');
  });
});

describe('deviceWriteMethodsVerdict', () => {
  it('passes with what the device characteristic offers, as Bluefy does without the global class', () => {
    const methods = { writeValueWithoutResponse: true, writeValueWithResponse: true, writeValue: true };
    expect(deviceWriteMethodsVerdict(methods)).toEqual({
      status: 'pass',
      note: message('verdict.deviceMethods', { methods: 'writeValueWithoutResponse, writeValueWithResponse, writeValue' }),
    });
    expect(deviceWriteMethodsVerdict(methods).note.en).toContain('device');
    expect(deviceWriteMethodsVerdict(methods).note['zh-TW']).toContain('裝置');
  });

  it('warns without writeValueWithoutResponse and fails without any write method', () => {
    const old = { writeValueWithoutResponse: false, writeValueWithResponse: false, writeValue: true };
    expect(deviceWriteMethodsVerdict(old)).toEqual({
      status: 'warn',
      note: message('verdict.noWithoutResponse', { methods: 'writeValue' }),
    });
    const none = { writeValueWithoutResponse: false, writeValueWithResponse: false, writeValue: false };
    expect(deviceWriteMethodsVerdict(none).status).toBe('fail');
  });

  it('describes the methods for the log', () => {
    expect(describeWriteMethods({ writeValueWithoutResponse: true, writeValueWithResponse: false, writeValue: true })).toBe(
      'writeValueWithoutResponse=yes, writeValueWithResponse=no, writeValue=yes',
    );
  });
});
