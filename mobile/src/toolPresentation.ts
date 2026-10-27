// Keep these symbols and verbs in step with ToolPresentation in the Mac app.
import * as brandData from './toolBrands.json';
import type { InstalledPlugin } from './types';

export type ToolIndicator = { kind: 'brand'; id: string; label: string }
  | { kind: 'mcpServer'; name: string; label: string }
  | { kind: 'symbol'; symbol: string; label: string };
const catalog: { id: string; label: string; executables: string[]; mcpAliases: string[]; symbol?: string }[] = brandData.catalog;
const brand = (id: string): ToolIndicator => ({ kind: 'brand', id, label: catalog.find(item => item.id === id)?.label || id });
const symbol = (name: string, label = 'Tool'): ToolIndicator => ({ kind: 'symbol', symbol: name, label });
export function brandGlyph(id: string): string | undefined { return (brandData.glyphs as Record<string, string>)[id]; }
export function toolMonogram(name: string): { letter: string; colorIndex: number } {
  let hash = 0x811c9dc5;
  const add = (byte: number) => { hash = Math.imul(hash ^ byte, 0x01000193) >>> 0; };
  for (const char of name.toLowerCase()) {
    const code = char.codePointAt(0)!;
    if (code < 0x80) add(code);
    else if (code < 0x800) { add(0xc0 | (code >> 6)); add(0x80 | (code & 0x3f)); }
    else if (code < 0x10000) { add(0xe0 | (code >> 12)); add(0x80 | ((code >> 6) & 0x3f)); add(0x80 | (code & 0x3f)); }
    else { add(0xf0 | (code >> 18)); add(0x80 | ((code >> 12) & 0x3f)); add(0x80 | ((code >> 6) & 0x3f)); add(0x80 | (code & 0x3f)); }
  }
  return { letter: name.toUpperCase().match(/[\p{L}\p{N}]/u)?.[0] || '?', colorIndex: hash % 7 };
}
const officialPlugins: Record<string, string> = {
  'sh.abstract.github': 'GitHub', 'sh.abstract.bitbucket': 'Bitbucket',
  'sh.abstract.linear': 'Linear', 'sh.abstract.jira': 'Jira',
};
function pluginTool(name: string): string | null {
  for (const prefix of ['mcp__abstract-plugins__', 'abstract-plugins_']) if (name.startsWith(prefix) && name.length > prefix.length) return name.slice(prefix.length);
  return null;
}
function pluginBrand(name: string, plugins: InstalledPlugin[]): string | null {
  const tool = pluginTool(name);
  if (!tool) return null;
  // The host publishes `<slug>_<tool>`. Only accept a unique installed
  // plugin match; a name alone is never evidence of a brand.
  const matches = plugins.filter(plugin => {
    const slug = plugin.name.toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 12).replace(/^-|-$/g, '') || 'plugin';
    return tool.startsWith(`${slug}_`);
  });
  return matches.length === 1 ? officialPlugins[matches[0].id] || '' : null;
}
function aliasEntry(server: string) {
  let key = server.toLowerCase();
  if (key.endsWith('-mcp')) key = key.slice(0, -4);
  if (key.startsWith('mcp-')) key = key.slice(4);
  return catalog.find(item => item.mcpAliases.includes(key));
}
function mcpIndicator(name: string): ToolIndicator | null {
  if (name.startsWith('mcp__')) {
    const server = name.slice(5).split('__')[0];
    if (!server) return null;
    const hit = aliasEntry(server);
    return hit ? brand(hit.id) : { kind: 'mcpServer', name: server, label: `${server} MCP server` };
  }
  const aliases = catalog.flatMap(item => item.mcpAliases.flatMap(alias => [alias, `${alias}-mcp`, `mcp-${alias}`]));
  for (const candidate of aliases.sort((a, b) => b.length - a.length))
    if (name.startsWith(`${candidate}_`) && name.length > candidate.length + 1) {
      const hit = aliasEntry(candidate);
      if (hit) return brand(hit.id);
    }
  return null;
}
export function unwrapShell(raw: string): string {
  const s = raw.trim();
  const match = s.match(/^(?:\/bin\/)?(?:zsh|bash|sh) -(?:lc|c) (["'])([\s\S]*)\1$/);
  if (!match) return s;
  return match[1] === '"' ? match[2].replace(/\\(["$`\\])/g, '$1') : match[2];
}
function splitSegments(command: string): string[] {
  const segments: string[] = [];
  let current = '', quote = '', escaped = false;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (escaped) { current += c; escaped = false; continue; }
    if (c === '\\' && quote !== "'") { current += c; escaped = true; continue; }
    if (quote) { current += c; if (c === quote) quote = ''; continue; }
    if (c === '"' || c === "'") { quote = c; current += c; continue; }
    if (c === '&' && command[i + 1] === '&') { segments.push(current); current = ''; i++; continue; }
    if (c === '|') { segments.push(current); current = ''; if (command[i + 1] === '|') i++; continue; }
    if (c === ';' || c === '\n') { segments.push(current); current = ''; continue; }
    current += c;
  }
  segments.push(current);
  return segments;
}
function tokenize(segment: string): string[] {
  const tokens: string[] = [];
  let current = '', quote = '', escaped = false, started = false;
  for (const c of segment) {
    if (escaped) { current += c; escaped = false; started = true; continue; }
    if (c === '\\' && quote !== "'") { escaped = true; started = true; continue; }
    if (quote) { if (c === quote) quote = ''; else current += c; started = true; continue; }
    if (c === '"' || c === "'") { quote = c; started = true; continue; }
    if (/\s/.test(c)) { if (started) tokens.push(current); current = ''; started = false; continue; }
    current += c; started = true;
  }
  if (started) tokens.push(current);
  return tokens;
}
const base = (token: string) => token.split('/').at(-1)?.toLowerCase() || '';
const assignment = (token: string) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(token);
function executable(tokens: string[], at: number): ToolIndicator | null {
  const token = tokens[at];
  if (!token || /[$`]/.test(token)) return null;
  const exe = base(token);
  if (exe === 'acli') return tokens[at + 1]?.toLowerCase() === 'jira' ? brand('Jira') : null;
  const hit = catalog.find(item => item.executables.includes(exe));
  return hit ? hit.symbol ? symbol(hit.symbol, hit.label) : brand(hit.id) : null;
}
function segmentIndicator(raw: string, depth: number): ToolIndicator | null {
  const tokens = tokenize(raw);
  if (tokens.some(token => /[$`]/.test(token))) return null;
  while (tokens.length) { tokens[0] = tokens[0].replace(/^\(+/, ''); if (tokens[0]) break; tokens.shift(); }
  let i = 0;
  const flags = (plain: string[], valued: string[]) => {
    while (i < tokens.length) {
      if (plain.includes(tokens[i])) i++;
      else if (valued.includes(tokens[i])) i += 2;
      else return !tokens[i].startsWith('-');
    }
    return true;
  };
  while (i < tokens.length) {
    if (assignment(tokens[i])) { i++; continue; }
    switch (base(tokens[i])) {
      case 'env': i++; while (assignment(tokens[i] || '')) i++; if (!flags(['-i'], ['-u'])) return null; while (assignment(tokens[i] || '')) i++; break;
      case 'sudo': i++; if (!flags(['-E', '-n', '-s', '-H'], ['-u', '-g'])) return null; break;
      case 'command': case 'builtin': case 'exec': case 'nohup': case 'time': i++; break;
      case 'nice': i++; if (tokens[i] === '-n') i += 2; break;
      case 'xargs': i++; if (!flags(['-0'], ['-I', '-n', '-P'])) return null; break;
      default: {
        const exe = base(tokens[i]);
        if (depth === 0 && ['sh', 'bash', 'zsh'].includes(exe) && ['-c', '-lc', '-cl'].includes(tokens[i + 1])) return commandIndicator(tokens[i + 2] || '', 1);
        let offset = 0;
        if (['npx', 'bunx', 'uvx'].includes(exe)) offset = 1;
        else if (exe === 'uv' && tokens[i + 1] === 'tool' && tokens[i + 2] === 'run') offset = 3;
        else if (({ npm: ['exec'], pnpm: ['dlx', 'exec'], yarn: ['dlx', 'exec'], uv: ['run'], pipx: ['run'], poetry: ['run'], bundle: ['exec'] } as Record<string, string[]>)[exe]?.includes(tokens[i + 1])) offset = 2;
        return (offset && executable(tokens, i + offset)) || executable(tokens, i);
      }
    }
  }
  return null;
}
function commandIndicator(command: string, depth = 0): ToolIndicator | null {
  for (const segment of splitSegments(command)) { const hit = segmentIndicator(segment, depth); if (hit) return hit; }
  return null;
}
export function resolveToolIndicator(name: string, input: any = {}, plugins: InstalledPlugin[] = [], skillUse = true): ToolIndicator {
  if (skillUse && (name.toLowerCase() === 'skill' || (name.toLowerCase() === 'bash' && /skills\/[^/]+\/SKILL\.md/.test(input?.command || '')))) return symbol('book.closed', 'Skill');
  if ((historyTool(name) && (['code_history', 'chat_excerpt'].includes(name) || name.startsWith('mcp__abstract-code-history__') || name.startsWith('abstract-code-history_')))
    || ['name_branch', 'mcp__abstract-branch__name_branch', 'abstract-branch_name_branch'].includes(name)) return brand('Abstract');
  if (pluginTool(name)) {
    const id = pluginBrand(name, plugins);
    return id === null ? brand('Abstract') : id ? brand(id) : symbol('puzzlepiece.extension', 'Plugin tool');
  }
  const mcp = mcpIndicator(name);
  if (mcp) return mcp;
  if (['bash', 'shell', 'command_execution', 'bashoutput'].includes(name.toLowerCase())) return commandIndicator(unwrapShell(String(input?.command || input?.cmd || ''))) || symbol('terminal', 'Terminal');
  return symbol(toolSymbol(name), name);
}
const symbols: Record<string, string> = {
  read: 'doc.text', read_file: 'doc.text', notebookread: 'doc.text', write: 'doc.badge.plus', write_file: 'doc.badge.plus',
  edit: 'pencil', edit_file: 'pencil', multiedit: 'pencil', notebookedit: 'pencil', applypatch: 'pencil', apply_patch: 'pencil', file_change: 'pencil', patch_apply: 'pencil',
  bash: 'terminal', shell: 'terminal', command_execution: 'terminal', bashoutput: 'terminal', js: 'terminal', js_reset: 'terminal',
  grep: 'magnifyingglass', glob: 'magnifyingglass', search: 'magnifyingglass', ls: 'magnifyingglass', toolsearch: 'magnifyingglass',
  webfetch: 'globe', web_fetch: 'globe', websearch: 'globe', web_search: 'globe',
  todowrite: 'checklist', todolist: 'checklist', todo_list: 'checklist',
  exitplanmode: 'list.bullet.clipboard', task: 'person.2', agent: 'person.2',
  skill: 'book.closed', askuserquestion: 'questionmark.bubble'
};
const done: Record<string, string> = {
  read: 'Read', read_file: 'Read', notebookread: 'Read', write: 'Created', write_file: 'Created', edit: 'Edited', edit_file: 'Edited', multiedit: 'Edited', notebookedit: 'Edited', applypatch: 'Edited', apply_patch: 'Edited', file_change: 'Edited', patch_apply: 'Edited',
  bash: 'Ran', shell: 'Ran', command_execution: 'Ran', bashoutput: 'Checked output', js: 'Ran', js_reset: 'Reset',
  grep: 'Searched', search: 'Searched', glob: 'Listed', ls: 'Listed', toolsearch: 'Looked up tools',
  webfetch: 'Fetched', web_fetch: 'Fetched', websearch: 'Searched the web', web_search: 'Searched the web',
  task: 'Delegated', agent: 'Delegated', todowrite: 'Updated plan', todolist: 'Updated plan', todo_list: 'Updated plan', exitplanmode: 'Proposed a plan', skill: 'Used skill', askuserquestion: 'Asked'
};
const active: Record<string, string> = {
  read: 'Reading', read_file: 'Reading', notebookread: 'Reading', write: 'Creating', write_file: 'Creating', edit: 'Editing', edit_file: 'Editing', multiedit: 'Editing', notebookedit: 'Editing', applypatch: 'Editing', apply_patch: 'Editing', file_change: 'Editing', patch_apply: 'Editing',
  bash: 'Running', shell: 'Running', command_execution: 'Running', js: 'Running', js_reset: 'Resetting',
  grep: 'Searching', search: 'Searching', glob: 'Listing', ls: 'Listing', toolsearch: 'Searching', webfetch: 'Fetching', web_fetch: 'Fetching', websearch: 'Searching', web_search: 'Searching',
  task: 'Delegating', agent: 'Delegating', todowrite: 'Updating plan', todolist: 'Updating plan', todo_list: 'Updating plan', skill: 'Using skill', askuserquestion: 'Asking'
};

/** Abstract's own code-history tools under any agent's spelling, mirroring `CodeHistory.tool(inStreamName:)` on the Mac: the bare name, `mcp__abstract-code-history__code_history`, or OpenCode's `abstract-code-history_code_history`. */
export function historyTool(name: string): 'code_history' | 'chat_excerpt' | null {
  for (const tool of ['code_history', 'chat_excerpt'] as const)
    if (name === tool || name.endsWith(`__${tool}`) || name.endsWith(`_${tool}`)) return tool;
  return null;
}
/** "220", "220-245" or "220:245" → {first, last}; mirrors `CodeHistoryService.lineRange`. */
export function parseLineRange(lines: unknown): { first: number; last: number } | null {
  if (typeof lines !== 'string') return null;
  const parts = lines.trim().split(/[-:–]/).map(part => part.trim());
  const first = Number(parts[0]);
  if (!parts[0] || !Number.isInteger(first) || first <= 0) return null;
  if (parts.length === 1) return { first, last: first };
  const last = Number(parts[1]);
  if (parts.length !== 2 || !Number.isInteger(last) || last < first) return null;
  return { first, last };
}
export function toolSymbol(name: string): string {
  return isJavaScriptTool(name) ? 'terminal' : symbols[name.toLowerCase()] || (name.startsWith('mcp__') ? 'puzzlepiece.extension' : 'wrench.and.screwdriver');
}
export function toolVerb(name: string, pending = false): string {
  const history = historyTool(name);
  if (history === 'code_history') return pending ? 'Looking up history of' : 'Looked up history of';
  if (history === 'chat_excerpt') return pending ? 'Reading more of an earlier chat' : 'Read more of an earlier chat';
  const key = name.toLowerCase();
  if (isJavaScriptTool(name)) return pending ? 'Running' : 'Ran';
  return (pending ? active[key] : done[key]) || (name.startsWith('mcp__') ? 'Used' : name.replace(/_/g, ' '));
}
function isJavaScriptTool(name: string): boolean {
  const key = name.toLowerCase();
  return key === 'js' || key.endsWith('__js');
}
export function toolKind(name: string): 'command' | 'edit' | 'explore' | 'other' {
  if (historyTool(name)) return 'explore';
  const key = name.toLowerCase();
  if (isJavaScriptTool(name) || ['bash', 'shell', 'command_execution', 'bashoutput', 'js_reset'].includes(key)) return 'command';
  if (['write', 'write_file', 'edit', 'edit_file', 'multiedit', 'notebookedit', 'applypatch', 'apply_patch', 'file_change', 'patch_apply'].includes(key)) return 'edit';
  if (['read', 'read_file', 'notebookread', 'grep', 'glob', 'search', 'ls', 'toolsearch', 'webfetch', 'web_fetch', 'websearch', 'web_search'].includes(key)) return 'explore';
  return 'other';
}
export function toolTarget(name: string, input: any): { text: string; path?: string } {
  const key = name.toLowerCase();
  if (isJavaScriptTool(name) || key === 'js_reset') {
    let args = input?.arguments || input;
    if (typeof args === 'string') {
      try { args = JSON.parse(args); } catch {
        args = { title: args.match(/["']title["']\s*:\s*(["'])(.*?)\1/)?.[2], code: args.match(/["']code["']\s*:\s*(["'])(.*?)\1/)?.[2] || args };
      }
    }
    const title = args?.title;
    const code = args?.code;
    return { text: String(title || code || (key === 'js_reset' ? 'JavaScript session' : 'JavaScript')).split('\n')[0] };
  }
  if (toolKind(key) === 'command') {
    const raw = String(input?.command || input?.cmd || '');
    const match = raw.match(/^(?:\/bin\/)?(?:zsh|bash|sh) -l?c (["'])([\s\S]*)\1$/);
    return { text: (match ? match[2] : raw).split('\n')[0] };
  }
  // An MCP call's arguments ride inside the item (Codex), sometimes as JSON text.
  let args = input?.arguments;
  if (typeof args === 'string') { try { args = JSON.parse(args); } catch { args = undefined; } }
  const field = (name: string) => input?.[name] ?? (args && typeof args === 'object' ? args[name] : undefined);
  const path = field('file_path') || field('notebook_path') || field('path') || input?.changes?.[0]?.path;
  if (typeof path === 'string' && path) {
    let text = path.split('/').filter(Boolean).at(-1) || path;
    // A history lookup names its lines too: "Diff.swift lines 220–245".
    if (historyTool(name) === 'code_history') {
      const lines = parseLineRange(field('lines'));
      if (lines) text += lines.first === lines.last ? ` line ${lines.first}` : ` lines ${lines.first}–${lines.last}`;
    }
    return { text, path };
  }
  if (key === 'file_change' && input?.changes?.length) return { text: `${input.changes.length} files` };
  for (const field of ['description', 'pattern', 'query', 'url', 'skill']) {
    if (typeof input?.[field] === 'string') return { text: input[field] };
  }
  if (name.startsWith('mcp__')) return { text: name.slice(5).replace(/__/g, ' · ').replace(/_/g, ' ') };
  return { text: '' };
}
