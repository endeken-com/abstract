// Only a reader's gesture changes whether the transcript follows new output.
// Layout changes and programmatic scrolling must not turn following off.
export class TranscriptFollow {
  private following = true;
  private gesture = false;

  get shouldFollow() { return this.following && !this.gesture; }
  get isGestureActive() { return this.gesture; }

  beginGesture() { this.gesture = true; }

  scroll(offset: number, viewport: number, content: number) {
    if (this.gesture) this.following = offset + viewport >= content - 80;
    return this.following;
  }

  endGesture(offset: number, viewport: number, content: number) {
    this.scroll(offset, viewport, content);
    this.gesture = false;
    return this.following;
  }

  stopFollowing() { this.following = false; this.gesture = false; }
  jump() { this.following = true; this.gesture = false; }
}
