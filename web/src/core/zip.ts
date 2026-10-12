/**
 * The little of the zip format that card and backup files need. Writing stores every entry as it is
 * (a JPEG does not shrink anyway). Reading accepts stored and deflated entries (what Python's zipfile
 * writes) and trusts nothing: sizes are checked before and while inflating, entries are only looked
 * up by exact name (never used as paths), and the CRC-32 must match.
 */

import { crc32 } from './protocol';

/** The file is not a usable zip, or an entry in it is damaged, too big or of a kind we do not read. */
export class ZipError extends Error {
  override name = 'ZipError';
}

export interface ZipEntry {
  readonly name: string;
  readonly data: Uint8Array;
}

const LOCAL = 0x04034b50;
const CENTRAL = 0x02014b50;
const END = 0x06054b50;
const UTF8_NAME = 0x0800; // general purpose flag bit 11

/** A zip with `entries` stored uncompressed. */
export function writeZip(entries: readonly ZipEntry[]): Uint8Array {
  const parts: Uint8Array[] = [];
  const directory: Uint8Array[] = [];
  let offset = 0;
  for (const { name, data } of entries) {
    const n = new TextEncoder().encode(name);
    const crc = crc32(data);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, LOCAL, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, UTF8_NAME, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, data.length, true);
    local.setUint32(22, data.length, true);
    local.setUint16(26, n.length, true);
    const central = new DataView(new ArrayBuffer(46));
    central.setUint32(0, CENTRAL, true);
    central.setUint16(4, 20, true);
    central.setUint16(6, 20, true);
    central.setUint16(8, UTF8_NAME, true);
    central.setUint32(16, crc, true);
    central.setUint32(20, data.length, true);
    central.setUint32(24, data.length, true);
    central.setUint16(28, n.length, true);
    central.setUint32(42, offset, true);
    parts.push(new Uint8Array(local.buffer), n, data);
    directory.push(new Uint8Array(central.buffer), n);
    offset += 30 + n.length + data.length;
  }
  const size = directory.reduce((sum, part) => sum + part.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, END, true);
  end.setUint16(8, entries.length, true);
  end.setUint16(10, entries.length, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  const all = [...parts, ...directory, new Uint8Array(end.buffer)];
  const out = new Uint8Array(all.reduce((sum, part) => sum + part.length, 0));
  let at = 0;
  for (const part of all) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

interface Member {
  method: number;
  flags: number;
  crc: number;
  compressed: number;
  size: number;
  offset: number;
}

export interface ZipArchive {
  /** The entry names, in the order of the file. */
  readonly names: string[];
  /** The entry's bytes; a ZipError when it is missing, bigger than `maxBytes`, damaged or unreadable. */
  read(name: string, maxBytes: number): Promise<Uint8Array>;
}

/** Inflate raw deflate data, giving up as soon as it is more than `max` bytes. */
async function inflate(data: Uint8Array, max: number): Promise<Uint8Array> {
  const reader = new Blob([data as BlobPart]).stream().pipeThrough(new DecompressionStream('deflate-raw')).getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > max) {
        await reader.cancel().catch(() => undefined);
        throw new ZipError(`an entry is bigger than ${max} bytes`);
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof ZipError) throw error;
    throw new ZipError('an entry cannot be decompressed');
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const chunk of chunks) {
    out.set(chunk, at);
    at += chunk.length;
  }
  return out;
}

/** The directory of `bytes`, which must be a zip; the entries are read (and inflated) one by one on request. */
export function openZip(bytes: Uint8Array): ZipArchive {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = -1;
  for (let at = bytes.length - 22; at >= Math.max(0, bytes.length - 22 - 65535); at--) {
    if (view.getUint32(at, true) === END) {
      end = at;
      break;
    }
  }
  if (end < 0) throw new ZipError('this is not a zip file');
  const count = view.getUint16(end + 10, true);
  let at = view.getUint32(end + 16, true);
  if (count === 0xffff || at === 0xffffffff) throw new ZipError('zip64 files are not supported');
  const members = new Map<string, Member>();
  for (let i = 0; i < count; i++) {
    if (at + 46 > bytes.length || view.getUint32(at, true) !== CENTRAL) throw new ZipError('the zip directory is damaged');
    const nameLength = view.getUint16(at + 28, true);
    const extraLength = view.getUint16(at + 30, true);
    const commentLength = view.getUint16(at + 32, true);
    if (at + 46 + nameLength > bytes.length) throw new ZipError('the zip directory is damaged');
    const name = new TextDecoder().decode(bytes.subarray(at + 46, at + 46 + nameLength));
    members.set(name, {
      flags: view.getUint16(at + 8, true),
      method: view.getUint16(at + 10, true),
      crc: view.getUint32(at + 16, true),
      compressed: view.getUint32(at + 20, true),
      size: view.getUint32(at + 24, true),
      offset: view.getUint32(at + 42, true),
    });
    at += 46 + nameLength + extraLength + commentLength;
  }

  return {
    names: [...members.keys()],
    async read(name, maxBytes) {
      const m = members.get(name);
      if (!m) throw new ZipError(`the zip has no entry ${name}`);
      if (m.flags & 1) throw new ZipError('encrypted zip entries are not supported');
      if (m.method !== 0 && m.method !== 8) throw new ZipError(`compression method ${m.method} is not supported`);
      if (m.size > maxBytes) throw new ZipError(`${name} is bigger than ${maxBytes} bytes`);
      if (m.offset + 30 > bytes.length || view.getUint32(m.offset, true) !== LOCAL) throw new ZipError('the zip is damaged');
      const start = m.offset + 30 + view.getUint16(m.offset + 26, true) + view.getUint16(m.offset + 28, true);
      if (start + m.compressed > bytes.length) throw new ZipError('the zip is cut off');
      const raw = bytes.subarray(start, start + m.compressed);
      const data = m.method === 0 ? raw : await inflate(raw, Math.min(maxBytes, m.size));
      if (data.length !== m.size || crc32(data) !== m.crc) throw new ZipError(`${name} is damaged (CRC mismatch)`);
      return Uint8Array.from(data);
    },
  };
}
