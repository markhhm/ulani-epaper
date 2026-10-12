/**
 * Wire protocol of the calendar: GATT layout, panel geometry, fixed commands
 * and replies, checksums, and the builders and parsers for the variable
 * messages.
 *
 * Everything here is pure (no Bluetooth, no DOM), so it runs the same in the
 * browser, in the Android app and in Vitest. Multi-byte integers on the wire
 * are big-endian. The expected bytes for every message are pinned by
 * shared/vectors/ulani-vectors.json.
 *
 * Byte constants are shared Uint8Array instances: treat them as read-only.
 */

// --- GATT layout -------------------------------------------------------------

/** 16-bit service the calendar advertises, in 128-bit form (used to find it). */
export const ADVERTISED_SERVICE = '0000a200-0000-1000-8000-00805f9b34fb';
/** Primary service holding the two protocol characteristics. */
export const SERVICE = '1234a200-7cbc-11e9-8f9e-2a86e4085a59';
/** Commands are written here (with response); replies arrive as notifications here. */
export const CHAR_COMMAND = '1234a201-7cbc-11e9-8f9e-2a86e4085a59';
/** Frame data is written here (without response); the final result is notified here. */
export const CHAR_IMAGE = '1234a202-7cbc-11e9-8f9e-2a86e4085a59';
/** Standard Device Information service (holds the two readable strings below). */
export const DEVICE_INFORMATION_SERVICE = '0000180a-0000-1000-8000-00805f9b34fb';
/** Device Information "Model Number String", e.g. `P7320E-B`. */
export const CHAR_MODEL_NUMBER = '00002a24-0000-1000-8000-00805f9b34fb';
/** Device Information "Firmware Revision String", e.g. `v1.0.09`. */
export const CHAR_FIRMWARE_REVISION = '00002a26-0000-1000-8000-00805f9b34fb';
/** Advertised names start with this, followed by a space and the last 6 hex digits of the MAC. */
export const ADVERTISED_NAME_PREFIX = 'ULANI';

// --- Panel and transfer limits ------------------------------------------------

export const WIDTH = 800;
export const HEIGHT = 480;
export const PIXELS_PER_BYTE = 2;
/** Size of one packed frame: 192 000 bytes. */
export const FRAME_BYTES = (WIDTH * HEIGHT) / PIXELS_PER_BYTE;
/** The four pages ("slots") the button cycles through. */
export const USER_SLOTS: readonly number[] = Object.freeze([1, 2, 3, 4]);
/** Header mode byte. Paperhue sends 1 (the LED blinks). */
export const DEFAULT_MODE = 1;
/** Largest image chunk written per packet. */
export const MAX_CHUNK = 230;
/** Smallest chunk any BLE link allows (default ATT MTU 23 minus the header). */
export const MIN_CHUNK = 20;
/** ATT header bytes: a write-without-response carries at most MTU - 3 bytes. */
export const ATT_HEADER = 3;

// --- Opcodes (first byte of a command and of its reply) -----------------------

export const OP_IMAGE_HEADER = 0x01;
export const OP_IMAGE_DATA = 0x02;
export const OP_UNLOCK = 0x04;
/** Notified unasked right after connecting (`05 00`). */
export const OP_DEVICE_READY = 0x05;
export const OP_BATTERY = 0x06;
export const OP_DISCONNECT = 0x09;
export const OP_DEVICE_INFO = 0x0a;
/** Switches the page on screen, like pressing the button. */
export const OP_SHOW_SLOT = 0x0b;
export const OP_GET_SLOT = 0x0c;

// --- Fixed commands (written to CHAR_COMMAND) ---------------------------------

/** Unlock: opcode 04 followed by the fixed ASCII model code "NB". Must precede uploads. */
export const CMD_UNLOCK = Uint8Array.of(0x04, 0x4e, 0x42);
export const CMD_BATTERY = Uint8Array.of(0x06, 0x00);
export const CMD_DEVICE_INFO = Uint8Array.of(0x0a, 0x00);
export const CMD_GET_SLOT = Uint8Array.of(0x0c, 0x00);
/** Goodbye: the calendar goes back to idle. */
export const CMD_DISCONNECT = Uint8Array.of(0x09, 0x03);

// --- Fixed replies ------------------------------------------------------------

export const RSP_UNLOCK_OK = Uint8Array.of(0x04, 0x00);
export const RSP_DEVICE_READY = Uint8Array.of(0x05, 0x00);
/** Header accepted: stream the frame now (within ~4 s). */
export const RSP_HEADER_OK = Uint8Array.of(0x01, 0x00);
/** Header refused: the device is busy. Not seen in testing, but handled. */
export const RSP_HEADER_BUSY = Uint8Array.of(0x01, 0x01);
/** The slot already holds a frame with this CRC; nothing to send. */
export const RSP_HEADER_SAME_IMAGE = Uint8Array.of(0x01, 0x02);
/** Frame stored. Notified on CHAR_IMAGE. */
export const RSP_DATA_OK = Uint8Array.of(0x02, 0x00);
/** Frame rejected (CRC mismatch, or the data stopped). Notified on CHAR_IMAGE. */
export const RSP_DATA_FAIL = Uint8Array.of(0x02, 0x01);
export const RSP_SHOW_SLOT_OK = Uint8Array.of(0x0b, 0x00);

/** Battery reply value that means "charging" instead of a level. */
export const BATTERY_CHARGING = 6;

// --- Errors and parsed messages -----------------------------------------------

/**
 * Base class of every error this code base raises on purpose. Each subclass
 * sets `name` explicitly, because minified builds rename classes.
 */
export class DeviceError extends Error {
  override name = 'DeviceError';

  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
  }
}

/** The device sent something we did not expect, or a message could not be built. */
export class ProtocolError extends DeviceError {
  override name = 'ProtocolError';
}

/** Battery state (`06 LL`). */
export interface Battery {
  /** 0 (lowest, time to charge) to 5 (full); null while charging. */
  readonly level: number | null;
  readonly charging: boolean;
}

/** Device info (`0A` + MAC(6) + ASCII serial). */
export interface DeviceInfo {
  /** Upper-case, colon separated, e.g. `11:22:33:44:55:66`. */
  readonly mac: string;
  readonly serial: string;
}

/** Page on screen and the CRC-32 of the frame it holds (`0C SS crc32`). */
export interface SlotStatus {
  readonly slot: number;
  /** Unsigned 32-bit value. */
  readonly crc32: number;
}

// --- Functions ------------------------------------------------------------------

function crcTable(entry: (n: number) => number): Uint32Array {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) table[n] = entry(n);
  return table;
}

// CRC-16/XMODEM of each high byte value (most significant bit first).
const CRC16_TABLE = crcTable((n) => {
  let crc = n << 8;
  for (let bit = 0; bit < 8; bit++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  return crc;
});

// CRC-32 (reflected polynomial 0xEDB88320) of each byte value.
const CRC32_TABLE = crcTable((n) => {
  let crc = n;
  for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
  return crc >>> 0;
});

/** CRC-16/XMODEM (poly 0x1021, init 0, no reflection, no final xor), as used in the image header. */
export function crc16(data: Uint8Array): number {
  let crc = 0;
  for (let i = 0; i < data.length; i++) {
    crc = ((crc << 8) & 0xffff) ^ CRC16_TABLE[((crc >> 8) ^ data[i]) & 0xff];
  }
  return crc;
}

/** Standard CRC-32 (IEEE 802.3, the zlib one) as an unsigned 32-bit number. */
export function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = (crc >>> 8) ^ CRC32_TABLE[(crc ^ data[i]) & 0xff];
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function checkByte(what: string, value: number): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xff) {
    throw new ProtocolError(`${what} must fit in one byte (0-255), got ${value}`);
  }
}

/**
 * The 13-byte header announcing an upload of `frame` to `slot`:
 * `01 | length (u32) | slot (u8) | mode (u8) | crc32 (u32) | crc16 (u16)`.
 *
 * @throws ProtocolError when `slot` or `mode` does not fit in one byte.
 */
export function buildImageHeader(frame: Uint8Array, slot: number, mode: number = DEFAULT_MODE): Uint8Array {
  checkByte('slot', slot);
  checkByte('mode', mode);
  if (frame.length > 0xffffffff) {
    throw new ProtocolError(`a frame of ${frame.length} bytes does not fit the header's length field`);
  }
  const header = new Uint8Array(13);
  const view = new DataView(header.buffer);
  view.setUint8(0, OP_IMAGE_HEADER);
  view.setUint32(1, frame.length);
  view.setUint8(5, slot);
  view.setUint8(6, mode);
  view.setUint32(7, crc32(frame));
  view.setUint16(11, crc16(frame));
  return header;
}

/**
 * Command that makes the panel display `slot` (`0B SS`).
 *
 * @throws ProtocolError when `slot` is not one of USER_SLOTS.
 */
export function buildShowSlot(slot: number): Uint8Array {
  if (!USER_SLOTS.includes(slot)) {
    throw new ProtocolError(`slot must be one of ${USER_SLOTS.join(', ')}, got ${slot}`);
  }
  return Uint8Array.of(OP_SHOW_SLOT, slot);
}

/** Throws unless `reply` starts with `opcode` and has at least `minLength` bytes. */
function expectReply(reply: Uint8Array, opcode: number, minLength: number): void {
  if (reply.length < minLength || reply[0] !== opcode) {
    const got = reply.length ? toHex(reply, ' ') : 'nothing';
    throw new ProtocolError(
      `expected a reply of at least ${minLength} bytes starting with ${toHex(Uint8Array.of(opcode))}, got ${got}`,
    );
  }
}

/**
 * Parse a battery reply (`06 LL`; `LL` = 6 means charging).
 *
 * @throws ProtocolError on a wrong opcode or a short reply.
 */
export function parseBattery(reply: Uint8Array): Battery {
  expectReply(reply, OP_BATTERY, 2);
  const value = reply[1];
  return value === BATTERY_CHARGING ? { level: null, charging: true } : { level: value, charging: false };
}

/**
 * Parse a get-slot reply (`0C SS` + CRC-32, at least 6 bytes).
 *
 * @throws ProtocolError on a wrong opcode or a short reply.
 */
export function parseSlot(reply: Uint8Array): SlotStatus {
  expectReply(reply, OP_GET_SLOT, 6);
  const view = new DataView(reply.buffer, reply.byteOffset, reply.byteLength);
  return { slot: reply[1], crc32: view.getUint32(2) };
}

/**
 * Parse a device-info reply (`0A` + MAC(6) + ASCII serial, at least 7 bytes).
 * Bytes of the serial outside ASCII decode as U+FFFD.
 *
 * @throws ProtocolError on a wrong opcode or a short reply.
 */
export function parseDeviceInfo(reply: Uint8Array): DeviceInfo {
  expectReply(reply, OP_DEVICE_INFO, 7);
  const mac = Array.from(reply.subarray(1, 7), (b) => b.toString(16).padStart(2, '0').toUpperCase()).join(':');
  let serial = '';
  for (const byte of reply.subarray(7)) serial += byte < 0x80 ? String.fromCharCode(byte) : '�';
  return { mac, serial };
}

/**
 * `data` split into consecutive pieces of `size` bytes (the last may be
 * shorter). Pieces may be views into `data`.
 *
 * @throws RangeError when `size` is not a positive integer.
 */
export function chunks(data: Uint8Array, size: number): Uint8Array[] {
  if (!Number.isInteger(size) || size <= 0) {
    throw new RangeError(`chunk size must be a positive integer, got ${size}`);
  }
  const pieces: Uint8Array[] = [];
  for (let start = 0; start < data.length; start += size) pieces.push(data.subarray(start, start + size));
  return pieces;
}

/** Whether two byte arrays hold the same bytes. */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** Lower-case hex, e.g. `toHex(CMD_GET_SLOT, ' ') === '0c 00'`. For messages and logs. */
export function toHex(data: Uint8Array, separator = ''): string {
  return Array.from(data, (b) => b.toString(16).padStart(2, '0')).join(separator);
}
