import { describe, expect, it } from 'vitest';
import * as p from '../src/core/protocol';
import { fromHex, protocolVectors as v, toHexString, vectorInput } from './vectors';

describe('checksums', () => {
  it('match every CRC vector', () => {
    for (const vector of v.crc) {
      const data = vectorInput(vector.input);
      expect(p.crc16(data).toString(16).padStart(4, '0')).toBe(vector.crc16);
      expect(p.crc32(data).toString(16).padStart(8, '0')).toBe(vector.crc32);
    }
  });

  it('match the frame vectors', () => {
    for (const [frame, vector] of [
      [vectorInput({ bands: true }), v.frame_bands],
      [vectorInput({ checker: true }), v.frame_checker],
    ] as const) {
      expect(p.crc16(frame).toString(16).padStart(4, '0')).toBe(vector.crc16);
      expect(p.crc32(frame).toString(16).padStart(8, '0')).toBe(vector.crc32);
    }
  });

  it('give CRC-32 as an unsigned number and read views at their offset', () => {
    const data = fromHex('ff313233343536373839ff');
    const view = data.subarray(1, 10);
    expect(p.crc32(view)).toBe(0xcbf43926);
    expect(p.crc16(view)).toBe(0x31c3);
    expect(p.crc32(Uint8Array.of(0))).toBe(0xd202ef8d);
    expect(p.crc32(Uint8Array.of(0))).toBeGreaterThan(0);
  });
});

describe('buildImageHeader', () => {
  it('matches every header vector', () => {
    for (const vector of v.image_header) {
      const header = p.buildImageHeader(vectorInput(vector.input), vector.slot, vector.mode);
      expect(toHexString(header)).toBe(vector.header);
    }
  });

  it('uses mode 1 by default', () => {
    const header = p.buildImageHeader(fromHex('313233343536373839'), 2);
    expect(toHexString(header)).toBe('01000000090201cbf4392631c3');
    expect(p.DEFAULT_MODE).toBe(1);
  });

  it('rejects a slot or mode that does not fit in a byte', () => {
    const frame = fromHex('00');
    for (const bad of [-1, 256, 1.5, Number.NaN]) {
      expect(() => p.buildImageHeader(frame, bad)).toThrow(p.ProtocolError);
      expect(() => p.buildImageHeader(frame, 1, bad)).toThrow(p.ProtocolError);
    }
    expect(toHexString(p.buildImageHeader(frame, 0, 255)).slice(10, 14)).toBe('00ff');
    expect(toHexString(p.buildImageHeader(frame, 255, 0)).slice(10, 14)).toBe('ff00');
  });
});

describe('buildShowSlot', () => {
  it('matches the vectors for every user slot', () => {
    expect(p.USER_SLOTS).toEqual([1, 2, 3, 4]);
    for (const slot of p.USER_SLOTS) {
      expect(toHexString(p.buildShowSlot(slot))).toBe(v.commands.show_slot[String(slot)]);
    }
    expect(Object.keys(v.commands.show_slot)).toEqual(p.USER_SLOTS.map(String));
  });

  it('rejects other slots', () => {
    for (const bad of [0, 5, 16, -1, 2.5]) expect(() => p.buildShowSlot(bad)).toThrow(p.ProtocolError);
  });
});

describe('reply parsers', () => {
  it('parse every battery vector', () => {
    for (const vector of v.replies.battery) {
      expect(p.parseBattery(fromHex(vector.reply))).toEqual({ level: vector.level, charging: vector.charging });
    }
  });

  it('parse every get-slot vector', () => {
    for (const vector of v.replies.get_slot) {
      expect(p.parseSlot(fromHex(vector.reply))).toEqual({ slot: vector.slot, crc32: parseInt(vector.crc32, 16) });
    }
  });

  it('parse every device-info vector', () => {
    for (const vector of v.replies.device_info) {
      expect(p.parseDeviceInfo(fromHex(vector.reply))).toEqual({ mac: vector.mac, serial: vector.serial });
    }
  });

  it('read replies that are views into a larger buffer', () => {
    const buffer = fromHex('ee0c022b9f7a43ee');
    expect(p.parseSlot(buffer.subarray(1, 7))).toEqual({ slot: 2, crc32: 0x2b9f7a43 });
  });

  it('ignore trailing bytes, keep NUL and replace non-ASCII serial bytes', () => {
    expect(p.parseBattery(fromHex('060499'))).toEqual({ level: 4, charging: false });
    expect(p.parseSlot(fromHex('0c01000000ff00'))).toEqual({ slot: 1, crc32: 255 });
    expect(p.parseDeviceInfo(fromHex('0aaabbccddeeff'))).toEqual({ mac: 'AA:BB:CC:DD:EE:FF', serial: '' });
    expect(p.parseDeviceInfo(fromHex('0a01020304050641ff42800043'))).toEqual({
      mac: '01:02:03:04:05:06',
      serial: 'A�B�\u0000C',
    });
  });

  it('reject a wrong opcode or a short reply', () => {
    for (const [parse, bad] of [
      [p.parseBattery, ['', '06', '0700', '0c00']],
      [p.parseSlot, ['', '0c', '0c022b9f7a', '0b022b9f7a43']],
      [p.parseDeviceInfo, ['', '0a', '0a1122334455', '0b11223344556655']],
    ] as const) {
      for (const hex of bad) expect(() => parse(fromHex(hex))).toThrow(p.ProtocolError);
    }
  });

  it('raise errors that are DeviceErrors with their own name', () => {
    try {
      p.parseBattery(fromHex('0500'));
      expect.unreachable();
    } catch (error) {
      expect(error).toBeInstanceOf(p.DeviceError);
      expect((error as Error).name).toBe('ProtocolError');
      expect((error as Error).message).toContain('05 00');
    }
  });
});

describe('chunks', () => {
  it('split into pieces of the given size, the last one shorter', () => {
    const data = Uint8Array.from({ length: 10 }, (_, i) => i);
    expect(p.chunks(data, 4).map((c) => [...c])).toEqual([[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]]);
    expect(p.chunks(data, 5).map((c) => c.length)).toEqual([5, 5]);
    expect(p.chunks(data, 100).map((c) => c.length)).toEqual([10]);
    expect(p.chunks(new Uint8Array(0), 3)).toEqual([]);
  });

  it('cover a frame in MAX_CHUNK pieces', () => {
    const frame = vectorInput({ checker: true });
    const pieces = p.chunks(frame, p.MAX_CHUNK);
    expect(pieces).toHaveLength(Math.ceil(p.FRAME_BYTES / p.MAX_CHUNK));
    expect(pieces.at(-1)!.length).toBe(p.FRAME_BYTES % p.MAX_CHUNK);
    const joined = new Uint8Array(p.FRAME_BYTES);
    let at = 0;
    for (const piece of pieces) {
      joined.set(piece, at);
      at += piece.length;
    }
    expect(p.bytesEqual(joined, frame)).toBe(true);
  });

  it('reject sizes that are not positive integers', () => {
    for (const bad of [0, -1, 1.5, Number.NaN, Infinity]) {
      expect(() => p.chunks(new Uint8Array(4), bad)).toThrow(RangeError);
    }
  });
});

describe('byte helpers', () => {
  it('compare bytes', () => {
    expect(p.bytesEqual(fromHex('0102'), fromHex('0102'))).toBe(true);
    expect(p.bytesEqual(fromHex('0102'), fromHex('0103'))).toBe(false);
    expect(p.bytesEqual(fromHex('0102'), fromHex('010200'))).toBe(false);
    expect(p.bytesEqual(new Uint8Array(0), new Uint8Array(0))).toBe(true);
    expect(p.bytesEqual(p.RSP_HEADER_OK, fromHex(v.replies.header.ok))).toBe(true);
  });

  it('format hex', () => {
    expect(p.toHex(p.CMD_GET_SLOT, ' ')).toBe('0c 00');
    expect(p.toHex(fromHex('00ff0a'))).toBe('00ff0a');
    expect(p.toHex(fromHex('00ff0a'), ':')).toBe('00:ff:0a');
    expect(p.toHex(new Uint8Array(0))).toBe('');
  });

  it('have the opcodes of the fixed messages', () => {
    expect(p.CMD_UNLOCK[0]).toBe(p.OP_UNLOCK);
    expect(p.CMD_BATTERY[0]).toBe(p.OP_BATTERY);
    expect(p.CMD_DEVICE_INFO[0]).toBe(p.OP_DEVICE_INFO);
    expect(p.CMD_GET_SLOT[0]).toBe(p.OP_GET_SLOT);
    expect(p.CMD_DISCONNECT[0]).toBe(p.OP_DISCONNECT);
    expect(p.RSP_DEVICE_READY[0]).toBe(p.OP_DEVICE_READY);
    expect(p.RSP_DATA_OK[0]).toBe(p.OP_IMAGE_DATA);
    expect(p.RSP_SHOW_SLOT_OK[0]).toBe(p.OP_SHOW_SLOT);
    expect(p.FRAME_BYTES).toBe(192000);
  });
});
