// Minimal, dependency-free ZIP entry reader — enough to pull books.sqlite / manifest.json out of a
// .khata. Reads the End-Of-Central-Directory record, walks the central directory to find the entry
// (authoritative sizes + compression method), then inflates the data from its local header.
// Handles STORE (0) and DEFLATE (8) — the only methods a .khata writer uses (spec §2).

import { inflateRawSync } from 'node:zlib';

const EOCD_SIG = 0x06054b50;
const CEN_SIG = 0x02014b50;

export function readZipEntry(buf, wantName) {
  // Find EOCD by scanning backwards (comment is normally empty, but tolerate up to 64 KiB).
  let eocd = -1;
  const minPos = Math.max(0, buf.length - 22 - 0xffff);
  for (let i = buf.length - 22; i >= minPos; i--) {
    if (buf.readUInt32LE(i) === EOCD_SIG) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('not a zip: no EOCD record');

  const cdCount = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16); // central directory offset

  for (let n = 0; n < cdCount; n++) {
    if (buf.readUInt32LE(p) !== CEN_SIG) throw new Error('corrupt central directory');
    const method = buf.readUInt16LE(p + 10);
    const compSize = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const localOff = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen);

    if (name === wantName) {
      // Read the LOCAL header to locate the data (its extra-field length can differ from central).
      const lNameLen = buf.readUInt16LE(localOff + 26);
      const lExtraLen = buf.readUInt16LE(localOff + 28);
      const dataStart = localOff + 30 + lNameLen + lExtraLen;
      const data = buf.subarray(dataStart, dataStart + compSize);
      if (method === 0) return Buffer.from(data);
      if (method === 8) return inflateRawSync(data);
      throw new Error(`unsupported zip compression method ${method} for ${wantName}`);
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  throw new Error(`zip entry not found: ${wantName}`);
}
