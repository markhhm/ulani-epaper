/**
 * A stand-in for the browser's Web Bluetooth objects (navigator.bluetooth,
 * BluetoothDevice, its GATT server, services and characteristics), enough
 * for WebBluetoothTransport. Like a browser, it allows one GATT operation at
 * a time and throws "GATT operation already in progress" otherwise; it
 * records every operation so tests can check order and methods.
 */

import {
  CHAR_COMMAND,
  CHAR_FIRMWARE_REVISION,
  CHAR_IMAGE,
  CHAR_MODEL_NUMBER,
  DEVICE_INFORMATION_SERVICE,
  SERVICE,
} from '../../src/core/protocol';

const text = new TextEncoder();

function networkError(message: string): DOMException {
  return new DOMException(message, 'NetworkError');
}

export interface WrittenValue {
  readonly method: 'writeValue' | 'writeValueWithResponse' | 'writeValueWithoutResponse';
  readonly bytes: Uint8Array;
  /** Byte length of the buffer behind the value that was passed. */
  readonly bufferLength: number;
}

export class FakeCharacteristic extends EventTarget {
  value: DataView | undefined;
  notifying = false;
  readonly written: WrittenValue[] = [];
  /** What readValue() returns. */
  stored: Uint8Array = new Uint8Array(0);

  constructor(
    readonly uuid: string,
    private readonly device: FakeDevice,
  ) {
    super();
  }

  readValue(): Promise<DataView> {
    return this.device.op(`read ${this.uuid}`, () => new DataView(this.stored.slice().buffer));
  }

  writeValue(value: BufferSource): Promise<void> {
    return this.write('writeValue', value);
  }

  writeValueWithResponse(value: BufferSource): Promise<void> {
    return this.write('writeValueWithResponse', value);
  }

  writeValueWithoutResponse(value: BufferSource): Promise<void> {
    return this.write('writeValueWithoutResponse', value);
  }

  startNotifications(): Promise<FakeCharacteristic> {
    return this.device.op(`notify ${this.uuid}`, () => {
      this.notifying = true;
      return this;
    });
  }

  /** The calendar notifies `bytes` on this characteristic. */
  emit(bytes: Uint8Array | readonly number[]): void {
    this.value = new DataView(Uint8Array.from(bytes).buffer);
    this.dispatchEvent(new Event('characteristicvaluechanged'));
  }

  private write(method: WrittenValue['method'], value: BufferSource): Promise<void> {
    const view = ArrayBuffer.isView(value)
      ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
      : new Uint8Array(value);
    const bufferLength = ArrayBuffer.isView(value) ? value.buffer.byteLength : value.byteLength;
    const bytes = view.slice();
    return this.device.op(`${method} ${this.uuid}`, () => {
      this.written.push({ method, bytes, bufferLength });
      this.device.onWrite?.(this, bytes);
    });
  }
}

export class FakeService {
  constructor(
    readonly uuid: string,
    private readonly device: FakeDevice,
    private readonly characteristics: Map<string, FakeCharacteristic>,
  ) {}

  getCharacteristic(uuid: string): Promise<FakeCharacteristic> {
    return this.device.op(`characteristic ${uuid}`, () => {
      const found = this.characteristics.get(uuid);
      if (!found) throw new DOMException('No Characteristics matching UUID found in Service.', 'NotFoundError');
      return found;
    });
  }
}

export class FakeServer {
  connected = false;
  connectCalls = 0;
  disconnectCalls = 0;
  /** `hang`: connect() never resolves (until disconnect()); an Error: it rejects with it. */
  connectBehaviour: 'ok' | 'hang' | Error = 'ok';
  private abortConnect: ((error: unknown) => void) | undefined;

  constructor(readonly device: FakeDevice) {}

  connect(): Promise<FakeServer> {
    this.connectCalls++;
    const behaviour = this.connectBehaviour;
    if (behaviour instanceof Error) return Promise.reject(behaviour);
    if (behaviour === 'hang') {
      return new Promise((_, reject) => {
        this.abortConnect = reject;
      });
    }
    this.connected = true;
    return Promise.resolve(this);
  }

  disconnect(): void {
    this.disconnectCalls++;
    this.abortConnect?.(new DOMException('Connection attempt aborted.', 'AbortError'));
    this.abortConnect = undefined;
    this.goDown();
  }

  /** The calendar drops the link. */
  drop(): void {
    this.goDown();
  }

  getPrimaryService(uuid: string): Promise<FakeService> {
    return this.device.op(`service ${uuid}`, () => {
      const found = this.device.services.get(uuid);
      if (!found) throw new DOMException('No Services matching UUID found in Device.', 'NotFoundError');
      return found;
    });
  }

  private goDown(): void {
    if (!this.connected) return;
    this.connected = false;
    this.device.releaseHeld(networkError('GATT Server is disconnected. Cannot perform GATT operations.'));
    this.device.dispatchEvent(new Event('gattserverdisconnected'));
  }
}

export class FakeDevice extends EventTarget {
  readonly id = 'fake-device';
  name: string | undefined = 'ULANI Calendar 123456';
  readonly gatt = new FakeServer(this);
  readonly services = new Map<string, FakeService>();
  readonly command: FakeCharacteristic;
  readonly image: FakeCharacteristic;
  readonly modelNumber: FakeCharacteristic;
  readonly firmwareRevision: FakeCharacteristic;
  /** Every GATT operation started, in order (`<kind> <uuid>`). */
  readonly log: string[] = [];
  /** Most operations that were ever in flight at once. */
  maxInFlight = 0;
  /** Makes the next operation whose label starts with the key fail with the error. */
  readonly failures = new Map<string, Error>();
  /** Called inside each successful write: the calendar's side. */
  onWrite: ((characteristic: FakeCharacteristic, bytes: Uint8Array) => void) | undefined;

  private inFlight = 0;
  private holding = false;
  private held: { resolve: () => void; reject: (error: unknown) => void }[] = [];

  constructor(options: { deviceInformation?: boolean } = {}) {
    super();
    this.command = new FakeCharacteristic(CHAR_COMMAND, this);
    this.image = new FakeCharacteristic(CHAR_IMAGE, this);
    this.modelNumber = new FakeCharacteristic(CHAR_MODEL_NUMBER, this);
    this.firmwareRevision = new FakeCharacteristic(CHAR_FIRMWARE_REVISION, this);
    this.modelNumber.stored = text.encode('P7320E-B');
    this.firmwareRevision.stored = text.encode('v1.0.09');
    this.addService(SERVICE, [this.command, this.image]);
    if (options.deviceInformation !== false) {
      this.addService(DEVICE_INFORMATION_SERVICE, [this.modelNumber, this.firmwareRevision]);
    }
  }

  /** Keep every operation in flight from now on, until release() or a disconnect. */
  hold(): void {
    this.holding = true;
  }

  release(): void {
    this.holding = false;
    for (const waiter of this.held.splice(0)) waiter.resolve();
  }

  releaseHeld(error: unknown): void {
    this.holding = false;
    for (const waiter of this.held.splice(0)) waiter.reject(error);
  }

  /** One GATT operation, the way a browser runs it: one at a time, only while connected. */
  async op<T>(label: string, work: () => T): Promise<T> {
    if (!this.gatt.connected) throw networkError('GATT Server is disconnected. Cannot perform GATT operations.');
    if (this.inFlight > 0) throw networkError('GATT operation already in progress.');
    this.inFlight++;
    this.maxInFlight = Math.max(this.maxInFlight, this.inFlight);
    this.log.push(label);
    try {
      await Promise.resolve();
      await Promise.resolve();
      if (this.holding) await new Promise<void>((resolve, reject) => this.held.push({ resolve, reject }));
      for (const [prefix, error] of this.failures) {
        if (label.startsWith(prefix)) {
          this.failures.delete(prefix);
          throw error;
        }
      }
      if (!this.gatt.connected) throw networkError('GATT Server is disconnected. Cannot perform GATT operations.');
      return work();
    } finally {
      this.inFlight--;
    }
  }

  private addService(uuid: string, characteristics: FakeCharacteristic[]): void {
    this.services.set(uuid, new FakeService(uuid, this, new Map(characteristics.map((c) => [c.uuid, c]))));
  }
}

export class FakeBluetooth {
  readonly requests: RequestDeviceOptions[] = [];
  /** `pick`: the user picks the device; an Error: requestDevice rejects with it. */
  chooser: 'pick' | Error = 'pick';

  constructor(readonly device: FakeDevice = new FakeDevice()) {}

  requestDevice(options: RequestDeviceOptions): Promise<FakeDevice> {
    this.requests.push(options);
    if (this.chooser instanceof Error) return Promise.reject(this.chooser);
    return Promise.resolve(this.device);
  }

  getAvailability(): Promise<boolean> {
    return Promise.resolve(true);
  }

  /** The devices the browser already lets this page use (what the user chose earlier). */
  granted: FakeDevice[] = [];

  getDevices(): Promise<FakeDevice[]> {
    return Promise.resolve(this.granted);
  }

  /** This fake, typed as the browser API. */
  get api(): Bluetooth {
    return this as unknown as Bluetooth;
  }
}

/**
 * Make `device` answer like a calendar: unlock, battery, get-slot (page 1 on
 * screen), goodbye, and image uploads (`02 00` once the announced length
 * arrived).
 * Replies are notified in a later microtask, as a browser dispatches events
 * after the write.
 */
export function answerLikeACalendar(device: FakeDevice): void {
  let expected = 0;
  let received = 0;
  device.onWrite = (characteristic, bytes) => {
    const later = (target: FakeCharacteristic, reply: number[]) => queueMicrotask(() => target.emit(reply));
    if (characteristic === device.image) {
      received += bytes.length;
      if (received === expected) later(device.image, [0x02, 0x00]);
      return;
    }
    switch (bytes[0]) {
      case 0x04:
        later(device.command, [0x04, 0x00]);
        break;
      case 0x06:
        later(device.command, [0x06, 0x05]);
        break;
      case 0x0c:
        later(device.command, [0x0c, 0x01, 0x00, 0x00, 0x00, 0x00]);
        break;
      case 0x09:
        later(device.command, [0x09, 0x00]);
        break;
      case 0x01:
        expected = new DataView(bytes.buffer).getUint32(1);
        received = 0;
        later(device.command, [0x01, 0x00]);
        break;
      default:
        break;
    }
  };
}
