export function composerInputHeights(windowHeight: number, keyboardOffset: number, topInset: number, fontScale: number) {
  // Keep room for the header, transcript and controls when the keyboard is open.
  const available = Math.max(56, windowHeight - keyboardOffset - topInset - 190);
  const minHeight = Math.min(Math.round(3 * 22 * fontScale + 12), available);
  return { minHeight, maxHeight: Math.max(minHeight, Math.min(180, available)) };
}
