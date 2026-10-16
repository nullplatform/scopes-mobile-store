/**
 * A zip's table of contents, read from its central directory with no
 * dependency: enough to tell an APK (AndroidManifest.xml) or an IPA
 * (Payload/<name>.app/Info.plist) from any other archive.
 */

import { ActionError } from "@nullplatform/plugin/package";

/** The entry names of a zip archive, read from its central directory; NOT_A_ZIP when the file is not one. */
export async function zipEntries(file: string): Promise<string[]> {
  const bytes = new Uint8Array(await Bun.file(file).arrayBuffer());
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  // The end-of-central-directory record is in the last 22 + 65535 bytes.
  const min = Math.max(0, bytes.length - 22 - 0xffff);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= min; i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd === -1) throw new ActionError("NOT_A_ZIP", `${file} is not a zip archive`);
  const count = view.getUint16(eocd + 10, true);
  const size = view.getUint32(eocd + 12, true);
  const offset = view.getUint32(eocd + 16, true);
  if (offset === 0xffffffff || size === 0xffffffff || count === 0xffff) {
    throw new ActionError("NOT_A_ZIP", `${file} is a zip64 archive, which this scope does not read`);
  }
  if (offset + size > bytes.length) throw new ActionError("NOT_A_ZIP", `${file} is a truncated zip archive`);
  const names: string[] = [];
  let p = offset;
  const decoder = new TextDecoder();
  for (let n = 0; n < count && p + 46 <= offset + size; n++) {
    if (view.getUint32(p, true) !== 0x02014b50) throw new ActionError("NOT_A_ZIP", `${file} has a corrupt central directory`);
    const nameLength = view.getUint16(p + 28, true);
    const extraLength = view.getUint16(p + 30, true);
    const commentLength = view.getUint16(p + 32, true);
    names.push(decoder.decode(bytes.subarray(p + 46, p + 46 + nameLength)));
    p += 46 + nameLength + extraLength + commentLength;
  }
  return names;
}
