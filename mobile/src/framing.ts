import { Buffer } from 'buffer';

/** Collect length-prefixed socket frames without copying the partial frame on every packet. */
export class FrameDecoder {
  private chunks: Buffer[] = [];
  private buffered = 0;
  private nextLength: number | null = null;

  push(chunk: Buffer): Buffer[] {
    if (chunk.length) { this.chunks.push(chunk); this.buffered += chunk.length; }
    const frames: Buffer[] = [];
    while (true) {
      if (this.nextLength === null) {
        if (this.buffered < 4) break;
        const length = this.take(4).readUInt32BE(0);
        if (length > 16 << 20) throw Error('Remote message is too large.');
        this.nextLength = length;
      }
      if (this.buffered < this.nextLength) break;
      frames.push(this.take(this.nextLength));
      this.nextLength = null;
    }
    return frames;
  }

  private take(length: number): Buffer {
    this.buffered -= length;
    if (!length) return Buffer.alloc(0);
    const first = this.chunks[0];
    if (first.length === length) { this.chunks.shift(); return first; }
    if (first.length > length) {
      this.chunks[0] = Buffer.from(first.subarray(length));
      // Buffer.subarray returns a plain Uint8Array in React Native's polyfill.
      return Buffer.from(first.subarray(0, length));
    }
    const result = Buffer.allocUnsafe(length);
    let copied = 0;
    while (copied < length) {
      const head = this.chunks[0];
      const size = Math.min(head.length, length - copied);
      head.copy(result, copied, 0, size);
      copied += size;
      if (size === head.length) this.chunks.shift(); else this.chunks[0] = Buffer.from(head.subarray(size));
    }
    return result;
  }
}
