// Keep these symbols and verbs in step with ToolPresentation in the Mac app.
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
