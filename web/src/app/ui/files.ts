/** Getting files in and out of the page (browser only). */

import { isNativeApp } from '../../ble/select';
import { saveToPhone } from '../android';

/** The bytes of a file the user chose. */
export async function readFile(file: Blob): Promise<Uint8Array> {
  return new Uint8Array(await file.arrayBuffer());
}

/**
 * Hand a file to the user: the "save as" screen in the Android app (a WebView cannot download), the
 * share sheet on phones (where "Save to Files" lives), a download elsewhere. Resolves true when the
 * file was handed over (a download cannot tell more), false when the user backed out.
 */
export async function saveFile(name: string, bytes: Uint8Array, type = 'application/octet-stream'): Promise<boolean> {
  if (isNativeApp()) return saveToPhone(name, bytes, type);
  const file = new File([bytes as BlobPart], name, { type });
  const coarse = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
  if (coarse && typeof navigator.canShare === 'function' && navigator.canShare({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title: name });
      return true;
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return false;
      // Not allowed here after all: download it instead.
    }
  }
  const url = URL.createObjectURL(file);
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
  return true;
}

/** `YYYY-MM-DD` in local time, for file names. */
export function dateStamp(date: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}`;
}
