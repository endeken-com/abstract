import type { ConsentDescription } from '@cloudflare/workers-oauth-provider';

const escape = (value: string) => value.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const STYLE = `
  body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 34rem; margin: 3rem auto; padding: 0 1.25rem; color: #1d1d1f; }
  h1 { font-size: 1.35rem; } .muted { color: #6e6e73; } .warn { color: #b25000; } .error { color: #c62828; }
  input[name=code] { font: 1.4rem ui-monospace, Menlo, monospace; letter-spacing: .15em; text-transform: uppercase; width: 11ch; padding: .3rem .5rem; }
  button { font: inherit; padding: .45rem 1rem; margin-right: .5rem; }
  @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #f5f5f7; } .muted { color: #a1a1a6; } }`;

/**
 * The authorize page (ABS-218; ABS-220 refines it): who is asking, where the
 * tokens go, and a field for the connection code your Mac shows. The decision
 * itself is made on the Mac, which picks the projects.
 */
export function codePage(details: ConsentDescription, handle: string, error?: string): string {
  const name = escape(details.clientName);
  const origin = details.clientDomain
    ? `Published by <strong>${escape(details.clientDomain)}</strong>.`
    : 'This app registered itself, so its name is not verified.';
  return `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connect ${name} to Abstract</title><style>${STYLE}</style>
<h1>Connect ${name} to Abstract</h1>
<p>${origin} Access will be sent to <strong>${escape(details.redirectHost)}</strong>.</p>
${details.redirectIsLoopback ? '<p class="warn"><strong>This sends access to an app on your computer.</strong> Continue only if you just started connecting from it.</p>' : ''}
<p>It asks to <strong>read your open chats</strong> (${details.scope.map(escape).join(', ') || 'chats:read'}). It can't send, run or change anything.</p>
<p class="muted">On your Mac, open Abstract › Settings › Devices › Remote access › <em>Connect an assistant</em>, and type the code it shows. Your Mac then asks you to allow it and which projects it may read.</p>
${error ? `<p class="error">${escape(error)}</p>` : ''}
<form method="post">
  <input type="hidden" name="handle" value="${escape(handle)}">
  <p><input name="code" autocomplete="one-time-code" autocapitalize="characters" spellcheck="false" placeholder="XXXX-XXXX" maxlength="9" required autofocus></p>
  <p><button name="decision" value="continue">Continue</button><button name="decision" value="deny" formnovalidate>Cancel</button></p>
</form>
<p class="muted">After you continue, this page waits up to two minutes for your Mac.</p>
</html>`;
}

export function messagePage(title: string, text: string, status = 400): Response {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><title>${escape(title)}</title><style>${STYLE}</style>
<h1>${escape(title)}</h1><p>${escape(text)}</p></html>`, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'", 'X-Frame-Options': 'DENY' },
  });
}

/** No framing, no scripts: the page can't be embedded or made to run anything. */
export function pageHeaders(headers: Headers): Headers {
  headers.set('Content-Type', 'text/html; charset=utf-8');
  headers.set('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
  headers.set('X-Frame-Options', 'DENY');
  headers.set('Cache-Control', 'no-store');
  return headers;
}
