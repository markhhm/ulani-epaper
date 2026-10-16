/**
 * Shared test vectors: every JSON file in ../shared/vectors (relative to
 * web/), loaded at test time. The same files pin the expected bytes for every
 * implementation of the protocol.
 *
 * The helpers below build vector inputs on their own (no code under test), so
 * a test can compare the library's output against them.
 */

const files = import.meta.glob<unknown>('../../shared/vectors/*.json', { eager: true, import: 'default' });

/** Parsed vector files by file name, e.g. `ulani-vectors.json`. */
export const vectorFiles: Readonly<Record<string, unknown>> = Object.freeze(
  Object.fromEntries(Object.entries(files).map(([path, data]) => [path.slice(path.lastIndexOf('/') + 1), data])),
);

/** The parsed vector file `name`; throws when it is missing. */
export function vectorFile<T>(name: string): T {
  if (!(name in vectorFiles)) {
    throw new Error(`no vector file ${name} in shared/vectors (found: ${Object.keys(vectorFiles).join(', ')})`);
  }
  return vectorFiles[name] as T;
}

/** How a vector describes the bytes it applies to. */
export type VectorInput =
  | { readonly hex: string }
  | { readonly repeat_hex: string; readonly count: number }
  | { readonly bands: true }
  | { readonly checker: true };

type Hex = string;
type Rgb = [number, number, number];

/** Layout of shared/vectors/ulani-vectors.json (version 1). Hex strings are lower-case. */
export interface ProtocolVectors {
  version: number;
  panel: {
    width: number;
    height: number;
    pixels_per_byte: number;
    frame_bytes: number;
    user_slots: number[];
    max_chunk: number;
  };
  gatt: {
    advertised_service: string;
    service: string;
    command: string;
    image: string;
    model_number: string;
    firmware_revision: string;
  };
  palette: { index: number; name: string; rgb: Rgb }[];
  crc: { input: VectorInput; crc16: Hex; crc32: Hex }[];
  image_header: { input: VectorInput; slot: number; mode: number; header: Hex }[];
  commands: {
    unlock: Hex;
    battery: Hex;
    device_info: Hex;
    get_slot: Hex;
    disconnect: Hex;
    show_slot: Record<string, Hex>;
  };
  replies: {
    unlock_ok: Hex;
    header: { ok: Hex; busy: Hex; same_image: Hex };
    data: { ok: Hex; fail: Hex };
    show_slot_ok: Hex;
    device_ready: Hex;
    battery: { reply: Hex; level: number | null; charging: boolean }[];
    get_slot: { reply: Hex; slot: number; crc32: Hex }[];
    device_info: { reply: Hex; mac: string; serial: string }[];
  };
  packing: { indices: number[]; packed: Hex }[];
  nearest_colour: { rgb: Rgb; index: number }[];
  frame_bands: { description: string; crc32: Hex; crc16: Hex; first_row_packed: Hex };
  frame_checker: { description: string; crc32: Hex; crc16: Hex; first_row_packed: Hex; last_row_packed: Hex };
  push_order: { shown: number; slots: number[]; order: number[] }[];
}

export const protocolVectors: ProtocolVectors = vectorFile<ProtocolVectors>('ulani-vectors.json');

/** Layout of shared/vectors/dither-vectors.json (version 1). */
export interface DitherVectors {
  version: number;
  kernel: [number, number, number][];
  divisor: number;
  strengths: number[];
  keep_in_range: { in: Rgb; out: Rgb }[];
  images: {
    name: string;
    width: number;
    height: number;
    /** 3 bytes per pixel, row-major. */
    rgb: Hex;
    results: {
      strength: number;
      /** One hex digit (palette index) per pixel, row-major. */
      indices: string;
      lift: number;
      scale: number;
    }[];
  }[];
}

export const ditherVectors: DitherVectors = vectorFile<DitherVectors>('dither-vectors.json');

/** Layout of shared/vectors/natural-vectors.json (version 2; shared/DITHER.md §6). */
export interface NaturalVectors {
  version: number;
  /** Per key of shared/dither/natural-tables.json: SHA-256 of its values as little-endian binary64, in JSON order. */
  tables_sha256: Record<string, Hex>;
  strengths: number[];
  /** Step A of one colour. */
  colours: {
    name: string;
    rgb: Hex;
    /** Three doubles as C99 hex floats. */
    target: [string, string, string];
    /** -1 for near-grey (black and white only), else the hue sector 0-4. */
    set: number;
  }[];
  images: {
    name: string;
    width: number;
    height: number;
    /** 3 bytes per pixel, row-major. */
    rgb: Hex;
    /** `indices`: one hex digit (palette index) per pixel, row-major. */
    results: { strength: number; indices: string }[];
  }[];
  frames: {
    name: string;
    width: number;
    height: number;
    /** Base64 of the raw DEFLATE (no zlib header) of the RGB bytes. */
    rgb_deflate: string;
    /** `sha256`: of the indices, one byte per pixel. */
    results: { strength: number; sha256: Hex }[];
  }[];
}

export const naturalVectors: NaturalVectors = vectorFile<NaturalVectors>('natural-vectors.json');

/** Layout of shared/vectors/fit-vectors.json (version 1). */
export interface FitVectors {
  version: number;
  panel: [number, number];
  placements: {
    size: [number, number];
    mode: 'contain' | 'cover' | 'stretch';
    /** Box read from the picture: left, top, right, bottom. */
    source: [number, number, number, number];
    /** Where it lands on the panel: x, y, width, height. */
    target: [number, number, number, number];
  }[];
  flatten: { rgba: [number, number, number, number]; rgb: Rgb }[];
}

export const fitVectors: FitVectors = vectorFile<FitVectors>('fit-vectors.json');

const PANEL_WIDTH = 800;
const PANEL_HEIGHT = 480;

/** Bytes of a hex string (an even number of hex digits, no separators). */
export function fromHex(hex: string): Uint8Array {
  if (hex.length % 2 !== 0 || /[^0-9a-f]/i.test(hex)) throw new Error(`not a hex string: ${hex}`);
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16);
  return out;
}

/** Lower-case hex of `bytes`, no separators. */
export function toHexString(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Palette index of column `x` in the bands frame. */
export function bandIndex(x: number): number {
  return Math.min(Math.floor(x / 114), 6);
}

/** Palette index of pixel (x, y) in the checker frame. */
export function checkerIndex(x: number, y: number): number {
  return (Math.floor(x / 115) + Math.floor(y / 69)) % 7;
}

/** A panel-sized frame of `indexAt(x, y)`, packed two pixels per byte, first pixel in the high nibble. */
export function packedFrame(indexAt: (x: number, y: number) => number): Uint8Array {
  const out = new Uint8Array((PANEL_WIDTH * PANEL_HEIGHT) / 2);
  let o = 0;
  for (let y = 0; y < PANEL_HEIGHT; y++) {
    for (let x = 0; x < PANEL_WIDTH; x += 2) out[o++] = (indexAt(x, y) << 4) | indexAt(x + 1, y);
  }
  return out;
}

export const bandsFrame = (): Uint8Array => packedFrame((x) => bandIndex(x));
export const checkerFrame = (): Uint8Array => packedFrame(checkerIndex);

/** An RGBA image (alpha `alpha` everywhere) of `width` x `height` pixels given as hex RGB, 3 bytes per pixel. */
export function rgbHexImage(width: number, height: number, rgb: string, alpha = 255): {
  width: number;
  height: number;
  data: Uint8ClampedArray;
} {
  const bytes = fromHex(rgb);
  if (bytes.length !== width * height * 3) throw new Error(`expected ${width * height * 3} RGB bytes, got ${bytes.length}`);
  const data = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    data[4 * i] = bytes[3 * i];
    data[4 * i + 1] = bytes[3 * i + 1];
    data[4 * i + 2] = bytes[3 * i + 2];
    data[4 * i + 3] = alpha;
  }
  return { width, height, data };
}

/** A panel-sized RGBA image whose pixel (x, y) is `rgbAt(x, y)`, opaque. */
export function panelImage(rgbAt: (x: number, y: number) => readonly [number, number, number]): {
  width: number;
  height: number;
  data: Uint8ClampedArray;
} {
  const data = new Uint8ClampedArray(PANEL_WIDTH * PANEL_HEIGHT * 4);
  let o = 0;
  for (let y = 0; y < PANEL_HEIGHT; y++) {
    for (let x = 0; x < PANEL_WIDTH; x++) {
      const [r, g, b] = rgbAt(x, y);
      data[o++] = r;
      data[o++] = g;
      data[o++] = b;
      data[o++] = 255;
    }
  }
  return { width: PANEL_WIDTH, height: PANEL_HEIGHT, data };
}

/** Indices given as one hex digit per pixel. */
export function digitIndices(digits: string): Uint8Array {
  return Uint8Array.from(digits, (d) => parseInt(d, 16));
}

/** One hex digit per index. */
export function indexDigits(indices: Uint8Array): string {
  return Array.from(indices, (i) => i.toString(16)).join('');
}

/** The bytes a vector's `input` describes. */
export function vectorInput(input: VectorInput): Uint8Array {
  if ('hex' in input) return fromHex(input.hex);
  if ('repeat_hex' in input) {
    const unit = fromHex(input.repeat_hex);
    const out = new Uint8Array(unit.length * input.count);
    for (let i = 0; i < input.count; i++) out.set(unit, i * unit.length);
    return out;
  }
  if ('bands' in input) return bandsFrame();
  return checkerFrame();
}
