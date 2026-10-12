/**
 * In-memory Transport for tests: no Bluetooth, no timers. A test scripts the
 * calendar's side by answering writes (`respond`) and pushing notifications
 * (`notify`), and inspects what the code under test wrote (`writes`).
 */

import {
  type DisconnectReason,
  type ProtocolCharacteristic,
  type ReadableCharacteristic,
  type Transport,
  TransportError,
  type TransportNotification,
  type Unsubscribe,
  type WriteMode,
} from '../src/ble/transport';

export interface RecordedWrite {
  readonly characteristic: ProtocolCharacteristic;
  readonly data: Uint8Array;
  readonly mode: WriteMode;
}

/** Answers one write; may call `fake.notify` (synchronously or later) to reply. */
export type Responder = (write: RecordedWrite, fake: FakeTransport) => void;

export class FakeTransport implements Transport {
  readonly kind = 'fake';
  deviceName: string | undefined = 'Fake Calendar 000000';
  connected = false;

  /** Every write, in order. */
  readonly writes: RecordedWrite[] = [];
  /** Every read, in order. */
  readonly reads: ReadableCharacteristic[] = [];
  /** Values returned by read(); missing entries read as empty. */
  readonly values = new Map<ReadableCharacteristic, Uint8Array>();
  /** Scripted calendar side; called after each write is recorded. */
  respond: Responder | undefined;
  /** What maxWriteLength() resolves to. */
  writeLength: number | undefined = 244;
  /** Number of connect() calls so far. */
  connectCalls = 0;
  /** Makes the next connect() calls fail with these errors, in order. */
  readonly connectFailures: TransportError[] = [];

  private readonly notificationListeners = new Set<(notification: TransportNotification) => void>();
  private readonly disconnectListeners = new Set<(reason: DisconnectReason) => void>();

  async connect(): Promise<void> {
    this.connectCalls++;
    const failure = this.connectFailures.shift();
    if (failure) throw failure;
    this.connected = true;
  }

  async disconnect(): Promise<void> {
    this.goDown('requested');
  }

  async write(characteristic: ProtocolCharacteristic, data: Uint8Array, mode: WriteMode): Promise<void> {
    this.requireLink();
    const write = { characteristic, data: data.slice(), mode };
    this.writes.push(write);
    this.respond?.(write, this);
  }

  async read(characteristic: ReadableCharacteristic): Promise<Uint8Array> {
    this.requireLink();
    this.reads.push(characteristic);
    return (this.values.get(characteristic) ?? new Uint8Array(0)).slice();
  }

  onNotification(listener: (notification: TransportNotification) => void): Unsubscribe {
    this.notificationListeners.add(listener);
    return () => this.notificationListeners.delete(listener);
  }

  onDisconnect(listener: (reason: DisconnectReason) => void): Unsubscribe {
    this.disconnectListeners.add(listener);
    return () => this.disconnectListeners.delete(listener);
  }

  async maxWriteLength(): Promise<number | undefined> {
    return this.writeLength;
  }

  /** Deliver a notification from the calendar to every listener. */
  notify(characteristic: ProtocolCharacteristic, value: Uint8Array | readonly number[]): void {
    const notification = { characteristic, value: Uint8Array.from(value) };
    for (const listener of [...this.notificationListeners]) listener(notification);
  }

  /** Simulate the calendar dropping the link. */
  drop(): void {
    this.goDown('lost');
  }

  private requireLink(): void {
    if (!this.connected) throw new TransportError('linkLost', 'not connected');
  }

  private goDown(reason: DisconnectReason): void {
    if (!this.connected) return;
    this.connected = false;
    for (const listener of [...this.disconnectListeners]) listener(reason);
  }
}
