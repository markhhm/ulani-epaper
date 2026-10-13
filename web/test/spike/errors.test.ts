import { describe, expect, it } from 'vitest';
import { TransportError, type TransportErrorCode } from '../../src/ble/transport';
import { DeviceError, ProtocolError } from '../../src/core/protocol';
import { LOCALES, t } from '../../src/i18n';
import { ConnectFailed, DeviceBusy, NoReply, UploadFailed } from '../../src/session/session';
import { DroppedWhileRedrawing, explainError, isAbort, NotConnected, technicalDetail } from '../../src/spike/errors';

const HAN = /[㐀-鿿]/;

const CODES: TransportErrorCode[] = ['unsupported', 'unavailable', 'cancelled', 'notFound', 'bondLost', 'linkLost', 'timeout'];

/** One of each error the page explains. */
function samples(): unknown[] {
  return [
    ...CODES.map((code) => new TransportError(code, `something about ${code}`)),
    new TransportError('unsupported', 'this browser has no writeValueWithoutResponse'),
    new TransportError('unsupported', 'firmwareRevision cannot be read'),
    new TransportError('unsupported', 'write image: GATT operation not permitted.'),
    new TransportError('linkLost', 'the device disconnected', { duringPairing: true }),
    new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true }),
    new TransportError('unavailable', 'choosing a device: location is off'),
    new TransportError('cancelled', 'requestDevice cancelled. (location is off)'),
    new NoReply(0x06, 'no reply'),
    new DeviceBusy('busy'),
    new UploadFailed(1, Uint8Array.of(2, 1), 'rejected'),
    new ProtocolError('odd reply'),
    new NotConnected('not connected'),
    new ConnectFailed(3, new TransportError('notFound', 'none'), false),
    new ConnectFailed(3, new TransportError('linkLost', 'dropped', { duringPairing: true }), true),
    new ConnectFailed(4, new TransportError('notFound', 'none'), false, true),
    new DeviceError('odd'),
    new DOMException('The operation was aborted.', 'AbortError'),
    new DroppedWhileRedrawing('the device dropped the link while redrawing its screen', {
      cause: new TransportError('linkLost', 'the device disconnected'),
    }),
    'boom',
  ];
}

describe('explainError', () => {
  it('explains every transport error code, differently, in both languages', () => {
    for (const locale of LOCALES) {
      const messages = new Set<string>();
      for (const code of CODES) {
        const explained = explainError(new TransportError(code, `something about ${code}`), locale);
        if (locale === 'zh-TW') expect(explained.message, code).toMatch(HAN);
        else expect(explained.message, code).not.toMatch(HAN);
        expect(explained.detail).toBe(`TransportError (${code}): something about ${code}`);
        messages.add(explained.message);
      }
      expect(messages.size).toBe(CODES.length);
    }
  });

  it('calls the hardware 裝置 / device, never 月曆 / calendar', () => {
    for (const error of samples()) {
      const zh = explainError(error, 'zh-TW').message;
      const en = explainError(error, 'en').message;
      expect(zh).not.toContain('月曆');
      expect(en).not.toMatch(/calendar/i);
      // The detail is shown under the message and copied into the log.
      const detail = explainError(error, 'en').detail;
      expect(detail).not.toContain('月曆');
      expect(detail).not.toMatch(/calendar/i);
      expect(zh).not.toMatch(/\s{2,}|^\s|\s$/);
      expect(en).not.toMatch(/\s{2,}|^\s|\s$/);
    }
    expect(explainError(new NotConnected('x'), 'zh-TW').message).toBe('還沒連上裝置。請先按「連線」。');
    expect(explainError(new NotConnected('x'), 'en').message).toBe('Not connected to the device yet. Tap "Connect" first.');
  });

  it('follows the current language by default', () => {
    expect(explainError(new DeviceBusy('busy')).message).toBe(t('error.busy'));
  });

  it('points at the right setting when a write method or the firmware read is missing', () => {
    expect(explainError(new TransportError('unsupported', 'this browser has no writeValueWithoutResponse'), 'zh-TW').message).toContain(
      '寫入方式',
    );
    expect(
      explainError(new TransportError('unsupported', 'firmwareRevision cannot be read: the Device Information service …'), 'zh-TW')
        .message,
    ).toContain('同步間隔');
    expect(explainError(new TransportError('unsupported', 'this browser has no Web Bluetooth'), 'zh-TW').message).toBe(
      t('bluetoothUnsupported', undefined, 'zh-TW'),
    );
    expect(explainError(new TransportError('unsupported', 'this browser has no Web Bluetooth'), 'en').message).toBe(
      t('bluetoothUnsupported', undefined, 'en'),
    );
  });

  it('tells how to pair again, pairing mode included, whenever the pairing does not work', () => {
    const steps = {
      'zh-TW': ['忘記此裝置', '按住裝置的按鈕約 5 秒', '閃綠燈', '同意配對'],
      en: ['forget this device', 'hold the device’s button about 5 s', 'blinks green', 'accept the pairing'],
    } as const;
    for (const locale of LOCALES) {
      const bond = explainError(new TransportError('bondLost', 'enable command notifications: refused'), locale).message;
      const drop = explainError(
        new TransportError('linkLost', 'the device disconnected (while enabling notifications)', { duringPairing: true }),
        locale,
      ).message;
      const stale = explainError(
        new ConnectFailed(3, new TransportError('linkLost', 'the device disconnected', { duringPairing: true }), true),
        locale,
      ).message;
      for (const text of [bond, drop, stale]) {
        let at = -1;
        for (const step of steps[locale]) {
          const next = text.indexOf(step, at + 1);
          expect(next, `${step} in ${text}`).toBeGreaterThan(at); // in this order
          at = next;
        }
      }
    }
    expect(explainError(new ConnectFailed(3, undefined, true), 'zh-TW').message).toContain('3 次');
    expect(explainError(new ConnectFailed(3, undefined, true), 'en').message).toContain('3 tries');
    // A plain drop does not send anyone to their settings.
    expect(explainError(new TransportError('linkLost', 'the device disconnected'), 'zh-TW').message).not.toContain('忘記');
    expect(explainError(new TransportError('linkLost', 'the device disconnected'), 'en').message).not.toContain('forget');
  });

  it('shows the pairing-mode hint when the device drops a connection attempt', () => {
    for (const locale of LOCALES) {
      const hint = t('connect.pairingHint', undefined, locale);
      const dropped = new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true });
      expect(explainError(dropped, locale).message).toContain(hint);
      // A drop on an open link is not about pairing mode.
      expect(explainError(new TransportError('linkLost', 'the device disconnected'), locale).message).not.toContain(hint);
      // Connecting gave up after such a drop, even when the last attempt failed otherwise.
      const failed = new ConnectFailed(4, new TransportError('notFound', 'none'), false, true);
      expect(explainError(failed, locale).message).toContain(hint);
      // Said once, also when the last attempt was the drop.
      const text = explainError(new ConnectFailed(4, dropped, false, true), locale).message;
      expect(text.indexOf(hint)).toBeGreaterThanOrEqual(0);
      expect(text.indexOf(hint)).toBe(text.lastIndexOf(hint));
      // Nobody is sent to forget the device for this.
      expect(text).not.toContain(locale === 'en' ? 'forget' : '忘記');
    }
  });

  it('words the pairing-mode hint as the owner asked, then says the device remembers one phone or computer', () => {
    expect(t('connect.pairingHint', undefined, 'zh-TW')).toBe(
      '第一次用這支手機連線？請長按裝置按鍵約 5 秒，綠燈閃爍（配對模式）後再按連線。' +
        '裝置一次只記得一支手機或電腦：和別的手機或電腦配對後，這裡的配對就會失效。',
    );
    expect(t('connect.pairingHint', undefined, 'en')).toBe(
      'First time with this phone? Hold the device’s button about 5 s until the light blinks green (pairing mode), then connect again. ' +
        'The device remembers one phone or computer at a time: pairing another one unpairs this one.',
    );
  });

  it('says once, wherever the pairing may be gone, that the device remembers one phone or computer at a time', () => {
    const one = { 'zh-TW': '裝置一次只記得一支手機或電腦', en: 'remembers one phone or computer at a time' } as const;
    const dropped = new TransportError('linkLost', 'the device disconnected', { duringPairing: true });
    for (const locale of LOCALES) {
      for (const error of [
        new TransportError('bondLost', 'connect: Unsupported device.'),
        dropped,
        new TransportError('linkLost', 'the device disconnected', { droppedWhileConnecting: true }),
        new ConnectFailed(3, dropped, true),
        new ConnectFailed(4, new TransportError('notFound', 'none'), false, true),
      ]) {
        const text = explainError(error, locale).message;
        expect(text.indexOf(one[locale]), text).toBeGreaterThanOrEqual(0);
        expect(text.indexOf(one[locale]), text).toBe(text.lastIndexOf(one[locale]));
      }
    }
  });

  it('sends a phone or a computer to its own Bluetooth settings to pair again', () => {
    expect(t('error.repairSteps', undefined, 'en')).toMatch(/^In the Bluetooth settings of this phone or computer, forget this device/);
    expect(t('error.repairSteps', undefined, 'zh-TW')).toMatch(/^請到這支手機或這台電腦的藍牙設定，對這台裝置按「忘記此裝置」/);
  });

  it('points at the write mode when the device refuses a write type', () => {
    const refused = new TransportError('unsupported', 'the device does not accept image data written with response (x)');
    expect(explainError(refused, 'zh-TW').message).toContain('寫入方式');
    expect(explainError(refused, 'en').message).toContain('Write mode');
    expect(explainError(new TransportError('unsupported', 'write image: GATT operation not permitted.'), 'zh-TW').message).toContain(
      '不允許',
    );
  });

  it('asks for Location where scans need it', () => {
    const off = 'choosing a device: location is off; Android 11 and older need it on to find Bluetooth devices';
    expect(explainError(new TransportError('unavailable', off), 'zh-TW').message).toContain('定位');
    expect(explainError(new TransportError('unavailable', off), 'en').message).toContain('Location');
    expect(explainError(new TransportError('cancelled', `requestDevice cancelled. (${off})`), 'zh-TW').message).toContain('定位');
    expect(explainError(new TransportError('cancelled', 'requestDevice cancelled.'), 'zh-TW').message).not.toContain('定位');
    // Not supported while choosing a device: the browser, not the operation.
    expect(explainError(new TransportError('unsupported', 'choosing a device: not supported'), 'en').message).toBe(
      t('bluetoothUnsupported', undefined, 'en'),
    );
  });

  it('explains session errors', () => {
    expect(explainError(new NoReply(0x06, 'no reply to opcode 0x06 within 5 s'), 'zh-TW').message).toContain('40 秒');
    expect(explainError(new NoReply(0x06, 'no reply to opcode 0x06 within 5 s'), 'en').message).toContain('40 s');
    expect(explainError(new DeviceBusy('busy'), 'zh-TW').message).toContain('一分鐘');
    const rejected = explainError(new UploadFailed(1, Uint8Array.of(2, 1), 'page 1: rejected'), 'zh-TW').message;
    expect(rejected).toContain('拒收');
    expect(rejected).not.toContain('等回應');
    expect(explainError(new ProtocolError('odd reply'), 'zh-TW').message).toContain('回應');
    expect(explainError(new NotConnected('not connected'), 'zh-TW').message).toContain('連線');
  });

  it('explains a stopped operation', () => {
    const abort = new DOMException('The operation was aborted.', 'AbortError');
    expect(isAbort(abort)).toBe(true);
    expect(isAbort(new Error('x'))).toBe(false);
    expect(explainError(abort, 'zh-TW')).toEqual({ message: '已停止。', detail: 'AbortError: The operation was aborted.' });
    expect(explainError(abort, 'en')).toEqual({ message: 'Stopped.', detail: 'AbortError: The operation was aborted.' });
  });

  it('explains the drop while the device redraws as expected, without sending anyone to Connect', () => {
    const dropped = new DroppedWhileRedrawing('the device dropped the link while redrawing its screen', {
      cause: new TransportError('linkLost', 'the device disconnected'),
    });
    expect(explainError(dropped, 'en').message).toBe(
      'The device dropped the link while redrawing its screen, as it does; it reconnects by itself. Try again once connected.',
    );
    expect(explainError(dropped, 'zh-TW').message).toBe(
      '裝置刷新畫面時會切斷藍牙連線，這是正常的；會自動重新連線，連上後再試一次。',
    );
    expect(explainError(dropped, 'en').detail).toBe(
      'DroppedWhileRedrawing: the device dropped the link while redrawing its screen\n' +
        'cause: TransportError (linkLost): the device disconnected',
    );
  });

  it('explains failed connection attempts through their cause', () => {
    const cause = new TransportError('notFound', 'no device found');
    const error = new ConnectFailed(3, cause, false);
    for (const locale of LOCALES) {
      const explained = explainError(error, locale);
      expect(explained.message).toContain(explainError(cause, locale).message);
      expect(explained.detail).toBe(
        'ConnectFailed: could not connect after 3 attempts: no device found\n' +
          'cause: TransportError (notFound): no device found',
      );
    }
    expect(explainError(error, 'zh-TW').message).toBe(`試了 3 次都連不上裝置。${explainError(cause, 'zh-TW').message}`);
    expect(explainError(error, 'en').message).toBe(`Could not connect after 3 tries. ${explainError(cause, 'en').message}`);
  });

  it('falls back for anything else', () => {
    expect(explainError(new DeviceError('odd'), 'zh-TW').message).toMatch(HAN);
    expect(explainError(new DeviceError('odd'), 'en').detail).toBe('DeviceError: odd');
    const explained = explainError('boom', 'zh-TW');
    expect(explained.message).toContain('未預期');
    expect(explained.detail).toBe('string: boom');
    expect(explainError('boom', 'en').message).toBe('Something unexpected went wrong. Copy the log and report it.');
  });
});

describe('technicalDetail', () => {
  it('follows causes, at most five levels', () => {
    let error: Error = new Error('root');
    for (let i = 0; i < 8; i++) error = new Error(`level ${i}`, { cause: error });
    const lines = technicalDetail(error).split('\n');
    expect(lines).toHaveLength(5);
    expect(lines[0]).toBe('Error: level 7');
    expect(lines[1]).toBe('cause: Error: level 6');
  });
});
