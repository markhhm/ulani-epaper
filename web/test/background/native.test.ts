import { describe, expect, it } from 'vitest';
import { bridgeBleClient, Native, nativeCalendarHost, type SyncHost } from '../../src/background/native';

/** The object SyncBridge.java adds to the page, without Android: records calls, answers when told. */
class FakeHost implements SyncHost {
  readonly calls: { id: string; method: string; args: Record<string, unknown> }[] = [];
  readonly answers = new Map<string, string>();
  finished: unknown;
  constructor(readonly page: { paperhueSync?: { settle(id: string): void; event(event: unknown): void } }) {}

  call(id: string, method: string, args: string): void {
    this.calls.push({ id, method, args: JSON.parse(args) as Record<string, unknown> });
  }
  take(id: string): string {
    const answer = this.answers.get(id) ?? '{"error":"no answer"}';
    this.answers.delete(id);
    return answer;
  }
  finish(result: string): void {
    this.finished = JSON.parse(result);
  }

  /** Answer the last call, as Java does: store the answer, then tell the page. */
  answer(reply: { value?: unknown; error?: string }): void {
    const call = this.calls.at(-1);
    if (!call) throw new Error('no call to answer');
    this.answers.set(call.id, JSON.stringify(reply));
    this.page.paperhueSync?.settle(call.id);
  }
}

function setUp() {
  const page: FakeHost['page'] = {};
  const host = new FakeHost(page);
  const native = new Native(host, page);
  return { host, native, page };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('the background sync bridge', () => {
  it('answers calls through take(), and rejects with the native error message', async () => {
    const { host, native } = setUp();
    const ok = native.call<number>('ble.getMtu', { deviceId: 'AA' });
    expect(host.calls[0]).toMatchObject({ method: 'ble.getMtu', args: { deviceId: 'AA' } });
    host.answer({ value: 247 });
    await expect(ok).resolves.toBe(247);
    const failing = native.call('ble.connect', { deviceId: 'AA' });
    host.answer({ error: 'connect timed out' });
    await expect(failing).rejects.toThrow('connect timed out');
  });

  it('carries Bluetooth bytes as hex both ways, and delivers notifications and drops', async () => {
    const { host, native, page } = setUp();
    const client = bridgeBleClient(native, 'AA:BB');
    expect(await client.requestDevice()).toEqual({ deviceId: 'AA:BB' });

    const drops: string[] = [];
    const connecting = client.connect('AA:BB', (id) => drops.push(id));
    host.answer({ value: null });
    await connecting;

    const values: number[][] = [];
    const notifying = client.startNotifications('AA:BB', 'svc', 'CHAR-1', (v) => values.push([...new Uint8Array(v.buffer, v.byteOffset, v.byteLength)]));
    host.answer({ value: null });
    await notifying;
    page.paperhueSync?.event({ type: 'notify', characteristic: 'char-1', value: '00ff10' });
    expect(values).toEqual([[0, 255, 16]]);

    const writing = client.writeWithoutResponse('AA:BB', 'svc', 'char-2', new DataView(Uint8Array.of(1, 171).buffer));
    expect(host.calls.at(-1)).toMatchObject({ method: 'ble.write', args: { characteristic: 'char-2', value: '01ab', withResponse: false } });
    host.answer({ value: null });
    await writing;

    const reading = client.read('AA:BB', 'svc', 'char-3');
    host.answer({ value: '4d31' });
    expect([...new Uint8Array((await reading).buffer)]).toEqual([0x4d, 0x31]);

    page.paperhueSync?.event({ type: 'disconnected' });
    await tick();
    expect(drops).toEqual(['AA:BB']);
  });

  it("reads the phone's calendars and downloads addresses through Android", async () => {
    const { host, native } = setUp();
    const calendar = nativeCalendarHost(native);
    const phone = calendar.phoneEvents(1, 2);
    expect(host.calls.at(-1)).toMatchObject({ method: 'calendar.events', args: { from: 1, to: 2 } });
    host.answer({ value: null }); // no calendar permission
    await expect(phone).resolves.toBeUndefined();
    const page = calendar.get('https://example.com/a.ics');
    host.answer({ value: { status: 200, text: 'BEGIN:VCALENDAR' } });
    await expect(page).resolves.toEqual({ status: 200, text: 'BEGIN:VCALENDAR' });
  });
});
