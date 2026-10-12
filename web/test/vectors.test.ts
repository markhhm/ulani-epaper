import { describe, expect, it } from 'vitest';
import { PALETTE } from '../src/core/palette';
import * as p from '../src/core/protocol';
import { STUCKI_DIVISOR, STUCKI_KERNEL } from '../src/core/dither';
import {
  bandsFrame,
  checkerFrame,
  fromHex,
  protocolVectors as v,
  toHexString,
  vectorFiles,
  vectorInput,
} from './vectors';

const ROW_BYTES = 400;

describe('shared vectors', () => {
  it('loads the protocol vectors from ../shared/vectors', () => {
    expect(Object.keys(vectorFiles)).toContain('ulani-vectors.json');
    expect(v.version).toBe(1);
  });

  it('match the panel constants', () => {
    expect(v.panel).toEqual({
      width: p.WIDTH,
      height: p.HEIGHT,
      pixels_per_byte: p.PIXELS_PER_BYTE,
      frame_bytes: p.FRAME_BYTES,
      user_slots: [...p.USER_SLOTS],
      max_chunk: p.MAX_CHUNK,
    });
  });

  it('match the GATT UUIDs', () => {
    expect(v.gatt).toEqual({
      advertised_service: p.ADVERTISED_SERVICE,
      service: p.SERVICE,
      command: p.CHAR_COMMAND,
      image: p.CHAR_IMAGE,
      model_number: p.CHAR_MODEL_NUMBER,
      firmware_revision: p.CHAR_FIRMWARE_REVISION,
    });
  });

  it('match the fixed commands and replies', () => {
    expect(toHexString(p.CMD_UNLOCK)).toBe(v.commands.unlock);
    expect(toHexString(p.CMD_BATTERY)).toBe(v.commands.battery);
    expect(toHexString(p.CMD_DEVICE_INFO)).toBe(v.commands.device_info);
    expect(toHexString(p.CMD_GET_SLOT)).toBe(v.commands.get_slot);
    expect(toHexString(p.CMD_DISCONNECT)).toBe(v.commands.disconnect);
    expect(toHexString(p.RSP_UNLOCK_OK)).toBe(v.replies.unlock_ok);
    expect(toHexString(p.RSP_HEADER_OK)).toBe(v.replies.header.ok);
    expect(toHexString(p.RSP_HEADER_BUSY)).toBe(v.replies.header.busy);
    expect(toHexString(p.RSP_HEADER_SAME_IMAGE)).toBe(v.replies.header.same_image);
    expect(toHexString(p.RSP_DATA_OK)).toBe(v.replies.data.ok);
    expect(toHexString(p.RSP_DATA_FAIL)).toBe(v.replies.data.fail);
    expect(toHexString(p.RSP_SHOW_SLOT_OK)).toBe(v.replies.show_slot_ok);
    expect(toHexString(p.RSP_DEVICE_READY)).toBe(v.replies.device_ready);
  });

  it('match the palette', () => {
    expect(PALETTE.map((c) => ({ index: c.index, name: c.name, rgb: [...c.rgb] }))).toEqual(v.palette);
  });

  it('describe frames the test helpers rebuild independently', () => {
    const bands = bandsFrame();
    const checker = checkerFrame();
    expect(bands.length).toBe(v.panel.frame_bytes);
    expect(toHexString(bands.subarray(0, ROW_BYTES))).toBe(v.frame_bands.first_row_packed);
    expect(toHexString(checker.subarray(0, ROW_BYTES))).toBe(v.frame_checker.first_row_packed);
    expect(toHexString(checker.subarray(checker.length - ROW_BYTES))).toBe(v.frame_checker.last_row_packed);
  });

  it('give each header the length of its input', () => {
    for (const vector of v.image_header) {
      const header = fromHex(vector.header);
      const length = new DataView(header.buffer).getUint32(1);
      expect(header.length).toBe(13);
      expect(length).toBe(vectorInput(vector.input).length);
      expect([header[5], header[6]]).toEqual([vector.slot, vector.mode]);
    }
  });
});

describe('Stucki kernel', () => {
  it('has twelve taps whose weights sum to the divisor', () => {
    expect(STUCKI_KERNEL).toHaveLength(12);
    expect(STUCKI_KERNEL.reduce((sum, [w]) => sum + w, 0)).toBe(STUCKI_DIVISOR);
  });
});
