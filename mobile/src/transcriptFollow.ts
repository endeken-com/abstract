// Only a reader's gesture changes whether the transcript follows new output.
// Layout changes and programmatic scrolling must not turn following off.
export class TranscriptFollow {
  private following = true;
  private gesture = false;
  private gestureStart = 0;
  private inspecting = false;

  get shouldFollow() { return this.following && !this.gesture; }
  get isGestureActive() { return this.gesture; }
  get shouldAnchor() { return !this.inspecting; }

  beginGesture(offset: number) { this.gesture = true; this.gestureStart = offset; }

  scroll(offset: number, viewport: number, content: number) {
    if (this.gesture) {
      const endTolerance = this.inspecting ? 8 : 80;
      this.following = offset >= this.gestureStart - 1 && offset + viewport >= content - endTolerance;
    }
    return this.following;
  }

  endGesture(offset: number, viewport: number, content: number) {
    this.scroll(offset, viewport, content);
    this.gesture = false;
    if (this.following) this.inspecting = false;
    return this.following;
  }

  stopFollowing() { this.following = false; this.gesture = false; this.inspecting = false; }
  inspect() { this.following = false; this.gesture = false; this.inspecting = true; }
  jump() { this.following = true; this.gesture = false; this.inspecting = false; }
}
