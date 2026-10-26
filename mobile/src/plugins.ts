import type { InstalledPlugin, PluginContribution, PluginPlace, PluginProjectChoice } from './types';
import type { MacView } from './macs';

// Plain words mirror PluginCapability.plainWords in AbstractCore.
export const capabilityWords: Record<string, string> = {
  'projects.read': "See your projects' names",
  'chats.read': "See your chats' titles, agents and progress",
  'chats.open': 'Open a chat when you click it',
  'storage.own': 'Remember its own settings on the Mac',
  network: 'Reach the web addresses it lists',
  secrets: 'Use the secrets you give it, without seeing them',
  'usage.read': 'See what your chats used and cost',
  'turns.read': 'See when your agents worked',
  'transcripts.read': "Read your chats' messages in the projects you pick",
  'automations.read': 'See your automations and when they last ran',
  'chats.create': 'Start chats in your projects',
  'chats.message': 'Send messages to your chats',
  'chats.control': 'Stop and resume your agents',
  'permissions.answer': "See and answer your agents' questions and permission requests",
  'automations.run': 'Run your automations',
  'review.comment': "Add comments to your chats' Review, for you to send or delete",
  'pullRequests.read': "Read your chats' pull requests: their checks, reviews and comments",
  'agent.tools': 'Give your agents tools it runs, subject to each project’s settings',
  cli: 'Run the command-line tool it names, with only the commands it lists',
};

export function capabilityLine(capability: string, transcriptProjects: string[]): string {
  if (capability === 'transcripts.read') {
    return transcriptProjects.length
      ? `Read your chats' messages in ${transcriptProjects.join(', ')}`
      : "Read your chats' messages in no projects yet";
  }
  return capabilityWords[capability] || capability;
}

export function transcriptProjectNames(keys: string[], choices: PluginProjectChoice[]): string[] {
  const byKey = new Map(choices.map(choice => [choice.key, choice.name]));
  return keys.flatMap(key => byKey.has(key) ? [byKey.get(key)!] : []);
}

export type MacPlugin = { mac: MacView; plugin: InstalledPlugin };
export type MacPluginContribution = { mac: MacView; plugin: InstalledPlugin; contribution: PluginContribution };

export function macPlugins(macs: MacView[]): MacPlugin[] {
  return macs.flatMap(mac => (mac.snapshot?.plugins || []).map(plugin => ({ mac, plugin })));
}

// Only usable plugins appear anywhere, as on the Mac: turning one off
// removes it from every place at once.
export function contributionsFor(plugins: InstalledPlugin[], place: PluginPlace): Array<{ plugin: InstalledPlugin; contribution: PluginContribution }> {
  return (plugins || []).filter(plugin => plugin.usable)
    .flatMap(plugin => plugin.contributions.filter(c => c.place === place).map(contribution => ({ plugin, contribution })));
}

export function macContributions(macs: MacView[], place: PluginPlace): MacPluginContribution[] {
  return macs.flatMap(mac => contributionsFor(mac.snapshot?.plugins || [], place)
    .map(({ plugin, contribution }) => ({ mac, plugin, contribution })));
}

// Remote request builders, kept with the logic so tests pin the wire shape.
export const setPluginEnabledArgs = (pluginId: string, enabled: boolean, transcriptProjectKeys?: string[] | null) =>
  ({ pluginId, enabled, transcriptProjectKeys: transcriptProjectKeys ?? null });
export const setPluginTranscriptProjectsArgs = (pluginId: string, keys: string[]) => ({ pluginId, keys });
export const pluginShowingArgs = (pluginId: string, place: PluginPlace, contributionId: string, chatId?: string | null) =>
  ({ pluginId, place, contributionId, chatId: chatId ?? null });
export const pluginMessageArgs = (pluginId: string, text: string, place: PluginPlace, contributionId: string, chatId?: string | null) =>
  ({ pluginId, text, place, contributionId, chatId: chatId ?? null });

// A menu item or palette command being run: handed to the plugin once its
// screen can hear it, like the Mac host does.
export const invokeEnvelope = (place: PluginPlace, contributionId: string, chatId?: string | null) =>
  JSON.stringify({ api: 1, type: 'invoke', payload: { place, contributionId, ...(chatId ? { chatId } : {}) } });

// `window.__abstractHostMessage` is what the shim installs; envelopes are
// JSON text from the Mac, passed through untouched.
export const hostMessageJS = (envelope: string) =>
  `window.__abstractHostMessage && window.__abstractHostMessage(${JSON.stringify(envelope)});true;`;

export const pluginShim = `(() => {
  const pending = new Map();
  const listeners = new Map();
  let next = 1;
  window.AbstractPlugin = {
    send(type, payload) {
      const id = String(next++);
      return new Promise((resolve) => {
        pending.set(id, resolve);
        window.ReactNativeWebView.postMessage(JSON.stringify({ api: 1, type, id, payload: payload || {} }));
      });
    },
    on(type, fn) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(fn);
    }
  };
  window.__abstractHostMessage = (text) => {
    let message;
    try { message = JSON.parse(text); } catch { return; }
    if (message.type === "context") {
      const root = document.documentElement.style;
      const tokens = (message.payload && message.payload.tokens) || {};
      for (const [name, value] of Object.entries(tokens)) root.setProperty("--abstract-" + name, value);
      if (message.payload && message.payload.fontFamily) root.setProperty("--abstract-font", message.payload.fontFamily);
    }
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message.payload);
      pending.delete(message.id);
      return;
    }
    for (const fn of listeners.get(message.type) || []) {
      try { fn(message.payload); } catch (error) { report(error); }
    }
  };
  function report(error) {
    try {
      window.ReactNativeWebView.postMessage(JSON.stringify({ api: 1, type: "__error", payload: { message: String(error) } }));
    } catch {}
  }
  window.addEventListener("error", (event) => report(event.message || "error"));
})();`;

const mime: Record<string, string> = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
  webp: 'image/webp', svg: 'image/svg+xml', woff2: 'font/woff2', woff: 'font/woff',
};

function resolvePath(from: string, ref: string): string {
  const clean = ref.split(/[?#]/)[0];
  try {
    const parts = clean.startsWith('/') ? [] : from.split('/').slice(0, -1);
    for (const part of clean.split('/')) {
      if (part === '..') parts.pop();
      else if (part && part !== '.') parts.push(decodeURIComponent(part));
    }
    return parts.join('/');
  } catch { return clean; }
}

const isExternal = (ref: string) => /^(?:[a-z][a-z0-9+.-]*:)?\/\//i.test(ref) || ref.startsWith('data:');

// One self-contained document from a package: styles, scripts and images
// inlined, nothing fetched. The package's own CSP names 'self', which an
// inlined document can't satisfy, so every document gets an inline policy.
export function buildPluginDocument(files: Record<string, string>, entry: string, decode: (base64: string) => string): string | null {
  const entryData = files[entry];
  if (entryData === undefined) return null;
  const text = (path: string) => files[path] === undefined ? null : decode(files[path]);
  const dataURI = (path: string) => {
    const data = files[path];
    if (data === undefined) return null;
    const ext = path.split('.').pop()?.toLowerCase() || '';
    return `data:${mime[ext] || 'application/octet-stream'};base64,${data}`;
  };
  const inlineCSS = (css: string, from: string) => css.replace(/url\(\s*(['"]?)([^)'"]+)\1\s*\)/g, (whole, _q, ref) => {
    if (isExternal(ref)) return whole;
    return dataURI(resolvePath(from, ref)) ? `url(${dataURI(resolvePath(from, ref))})` : whole;
  });
  let html = decode(entryData);
  html = html.replace(/<meta[^>]+http-equiv=["']?content-security-policy["']?[^>]*>/gi,
    '');
  html = html.replace(/<link\b[^>]*>/gi, tag => {
    const href = tag.match(/href=["']([^"']+)["']/i)?.[1];
    if (!href || isExternal(href) || !/rel=["']?stylesheet/i.test(tag)) return '';
    const path = resolvePath(entry, href);
    const css = text(path);
    return css === null ? '' : `<style>${inlineCSS(css, path).replace(/<\/style/gi, '<\\/style')}</style>`;
  });
  html = html.replace(/<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>(?:\s*<\/script>)?/gi, (whole, src) => {
    if (isExternal(src)) return '';
    const js = text(resolvePath(entry, src));
    return js === null ? '' : `<script>${js.replace(/<\/script/gi, '<\\/script')}</script>`;
  });
  html = html.replace(/(<img\b[^>]*\bsrc=["'])([^"']+)(["'])/gi, (whole, pre, src, post) => {
    if (isExternal(src)) return whole;
    const uri = dataURI(resolvePath(entry, src));
    return uri ? `${pre}${uri}${post}` : whole;
  });
  const policy = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'none'; base-uri 'none'">`;
  const shim = `<script>${pluginShim}</script>`;
  const head = `<head>${policy}${shim}</head>`;
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, match => `${match}${policy}${shim}`);
  if (/<html[^>]*>/i.test(html)) return html.replace(/<html[^>]*>/i, match => `${match}${head}`);
  return head + html;
}
