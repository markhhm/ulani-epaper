/** Getting files in and out of the page (browser only). */

/** The bytes of a file the user chose. */
export async function readFile(file: Blob): Promise<Uint8Array> {
  return new Uint8Array(await file.arrayBuffer());
}

/**
 * Hand a file to the user: the share sheet on phones (where "Save to Files" lives), a download
 * elsewhere. Resolves when it was handed over; a cancelled share sheet is not an error.
 */
export async function saveFile(name: string, bytes: Uint8Array, type = 'application/octet-stream'): Promise<void> {
  const file = new File([bytes as BlobPart], name, { type });
  const coarse = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
  if (coarse && typeof navigator.canShare === 'function' && navigator.canShare({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title: name });
      return;
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return;
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
}

/** `YYYY-MM-DD` in local time, for file names. */
export function dateStamp(date: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${p(date.getMonth() + 1)}-${p(date.getDate())}`;
}
