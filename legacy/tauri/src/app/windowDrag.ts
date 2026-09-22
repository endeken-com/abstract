import type { MouseEvent } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';

export const isMac = typeof navigator !== 'undefined' && /Mac/.test(navigator.platform);

const INTERACTIVE = 'button, a, input, textarea, select, [role="button"], [role="tab"], [role="menuitem"], [data-no-drag]';

/**
 * Makes a bar behave like a native title bar: press and drag moves the
 * window, double-click zooms it. WKWebView ignores `-webkit-app-region`, so
 * this calls the window API directly. Clicks that land on a control are left
 * alone so buttons inside the bar keep working.
 */
export function onTitleBarMouseDown(e: MouseEvent<HTMLElement>) {
  if (e.button !== 0) return;
  const target = e.target as HTMLElement;
  if (target.closest(INTERACTIVE)) return;
  const win = getCurrentWindow();
  if (e.detail === 2) {
    void win.toggleMaximize();
  } else {
    void win.startDragging();
  }
}

export const dragRegion = { onMouseDown: onTitleBarMouseDown } as const;
