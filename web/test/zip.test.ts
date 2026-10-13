import { deflateRawSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { crc32 } from '../src/core/protocol';
import { openZip, writeZip, ZipError } from '../src/core/zip';
import pythonZip from './fixtures/python-card.zip.b64?raw';

const bytes = (...values: number[]) => Uint8Array.from(values);
const text = (s: string) => new TextEncoder().encode(s);

/** A zip with one entry stored as `method`, `data` already compressed, for the cases writeZip cannot make. */
function rawZip(name: string, method: number, data: Uint8Array, usize: number, crc: number, flags = 0): Uint8Array {
  const n = text(name);
  const local = new DataView(new ArrayBuffer(30));
  local.setUint32(0, 0x04034b50, true);
  local.setUint16(4, 20, true);
  local.setUint16(6, flags, true);
  local.setUint16(8, method, true);
  local.setUint32(14, crc, true);
  local.setUint32(18, data.length, true);
  local.setUint32(22, usize, true);
  local.setUint16(26, n.length, true);
  const central = new DataView(new ArrayBuffer(46));
  central.setUint32(0, 0x02014b50, true);
  central.setUint16(4, 20, true);
  central.setUint16(6, 20, true);
  central.setUint16(8, flags, true);
  central.setUint16(10, method, true);
  central.setUint32(16, crc, true);
  central.setUint32(20, data.length, true);
  central.setUint32(24, usize, true);
  central.setUint16(28, n.length, true);
  const directoryAt = 30 + n.length + data.length;
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, 1, true);
  end.setUint16(10, 1, true);
  end.setUint32(12, 46 + n.length, true);
  end.setUint32(16, directoryAt, true);
  return Uint8Array.from([...new Uint8Array(local.buffer), ...n, ...data, ...new Uint8Array(central.buffer), ...n, ...new Uint8Array(end.buffer)]);
}

describe('writing and reading a zip', () => {
  it('gives back every entry as it was written', async () => {
    const big = Uint8Array.from({ length: 100_000 }, (_, i) => (i * 7) & 255);
    const zip = openZip(writeZip([{ name: 'card.json', data: text('{"牌卡":1}') }, { name: 'backgrounds/a.jpg', data: big }, { name: 'empty', data: new Uint8Array(0) }]));
    expect(zip.names).toEqual(['card.json', 'backgrounds/a.jpg', 'empty']);
    expect(await zip.read('card.json', 100)).toEqual(text('{"牌卡":1}'));
    expect(await zip.read('backgrounds/a.jpg', 200_000)).toEqual(big);
    expect(await zip.read('empty', 0)).toEqual(new Uint8Array(0));
  });

  it('reads a card file Python made (deflated json, stored image)', async () => {
    const zip = openZip(Uint8Array.from(atob(pythonZip.trim()), (c) => c.charCodeAt(0)));
    expect(zip.names).toEqual(['card.json', 'background.jpg']);
    expect(JSON.parse(new TextDecoder().decode(await zip.read('card.json', 65536))).texts[0].text).toBe('開會中');
    expect(await zip.read('background.jpg', 1000)).toEqual(Uint8Array.from({ length: 200 }, (_, i) => i));
  });
});

describe('a zip that is not to be trusted', () => {
  it('is refused when it is not a zip at all', () => {
    for (const junk of [new Uint8Array(0), bytes(1, 2, 3), text('PK nothing to see here, just text '.repeat(10))]) {
      expect(() => openZip(junk)).toThrow(ZipError);
    }
  });

  it('is refused when it is cut off', () => {
    const zip = writeZip([{ name: 'a', data: text('hello') }]);
    expect(() => openZip(zip.subarray(0, zip.length - 5))).toThrow(ZipError);
    expect(() => openZip(zip.subarray(0, 40))).toThrow(ZipError);
  });

  it('refuses an entry bigger than asked for, by its declared size and by its real size', async () => {
    const zip = openZip(writeZip([{ name: 'a', data: new Uint8Array(1000) }]));
    await expect(zip.read('a', 999)).rejects.toThrow(ZipError);
    const body = new Uint8Array(2_000_000); // inflates to 2 MB but says it is 10 bytes
    const lying = openZip(rawZip('bomb', 8, deflateRawSync(body), 10, crc32(body)));
    await expect(lying.read('bomb', 1000)).rejects.toThrow(ZipError);
  });

  it('refuses a damaged entry, an encrypted one and an unknown compression', async () => {
    const hello = text('hello');
    expect(await openZip(rawZip('a', 0, hello, 5, crc32(hello))).read('a', 10)).toEqual(hello);
    await expect(openZip(rawZip('a', 0, hello, 5, crc32(hello) ^ 1)).read('a', 10)).rejects.toThrow(/damaged|crc/i);
    await expect(openZip(rawZip('a', 0, hello, 5, crc32(hello), 1)).read('a', 10)).rejects.toThrow(/encrypted/i);
    await expect(openZip(rawZip('a', 12, hello, 5, crc32(hello))).read('a', 10)).rejects.toThrow(/compression/i);
    await expect(openZip(rawZip('a', 8, bytes(0xff, 0xff, 0xff, 0xff), 5, 0)).read('a', 10)).rejects.toThrow(ZipError);
  });

  it('says so for an entry that is not there', async () => {
    await expect(openZip(writeZip([{ name: 'a', data: text('x') }])).read('b', 10)).rejects.toThrow(ZipError);
  });
});
