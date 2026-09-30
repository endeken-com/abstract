// Keep these symbols and verbs in step with ToolPresentation in the Mac app.
const symbols: Record<string, string> = {
  read: 'doc.text', notebookread: 'doc.text', write: 'doc.badge.plus',
  edit: 'pencil', multiedit: 'pencil', notebookedit: 'pencil', applypatch: 'pencil', apply_patch: 'pencil', file_change: 'pencil', patch_apply: 'pencil',
  bash: 'terminal', shell: 'terminal', command_execution: 'terminal', bashoutput: 'terminal', js: 'terminal', js_reset: 'terminal',
  grep: 'magnifyingglass', glob: 'magnifyingglass', search: 'magnifyingglass', ls: 'magnifyingglass', toolsearch: 'magnifyingglass',
  webfetch: 'globe', websearch: 'globe', web_search: 'globe',
  todowrite: 'checklist', todolist: 'checklist', todo_list: 'checklist',
  exitplanmode: 'list.bullet.clipboard', task: 'person.2', agent: 'person.2',
  skill: 'book.closed', askuserquestion: 'questionmark.bubble'
};
const done: Record<string, string> = {
  read: 'Read', notebookread: 'Read', write: 'Created', edit: 'Edited', multiedit: 'Edited', notebookedit: 'Edited', applypatch: 'Edited', apply_patch: 'Edited', file_change: 'Edited', patch_apply: 'Edited',
  bash: 'Ran', shell: 'Ran', command_execution: 'Ran', bashoutput: 'Checked output', js: 'Ran', js_reset: 'Reset',
  grep: 'Searched', glob: 'Listed', ls: 'Listed', toolsearch: 'Looked up tools',
  webfetch: 'Fetched', websearch: 'Searched the web', web_search: 'Searched the web',
  task: 'Delegated', agent: 'Delegated', todowrite: 'Updated plan', todolist: 'Updated plan', todo_list: 'Updated plan', exitplanmode: 'Proposed a plan', skill: 'Used skill', askuserquestion: 'Asked'
};
const active: Record<string, string> = {
  read: 'Reading', notebookread: 'Reading', write: 'Creating', edit: 'Editing', multiedit: 'Editing', notebookedit: 'Editing', applypatch: 'Editing', apply_patch: 'Editing', file_change: 'Editing', patch_apply: 'Editing',
  bash: 'Running', shell: 'Running', command_execution: 'Running', js: 'Running', js_reset: 'Resetting',
  grep: 'Searching', glob: 'Listing', ls: 'Listing', toolsearch: 'Searching', webfetch: 'Fetching', websearch: 'Searching', web_search: 'Searching',
  task: 'Delegating', agent: 'Delegating', todowrite: 'Updating plan', todolist: 'Updating plan', todo_list: 'Updating plan', skill: 'Using skill', askuserquestion: 'Asking'
};

export function toolSymbol(name: string): string {
  return isJavaScriptTool(name) ? 'terminal' : symbols[name.toLowerCase()] || (name.startsWith('mcp__') ? 'puzzlepiece.extension' : 'wrench.and.screwdriver');
}
export function toolVerb(name: string, pending = false): string {
  const key = name.toLowerCase();
  if (isJavaScriptTool(name)) return pending ? 'Running' : 'Ran';
  return (pending ? active[key] : done[key]) || (name.startsWith('mcp__') ? 'Used' : name.replace(/_/g, ' '));
}
function isJavaScriptTool(name: string): boolean {
  const key = name.toLowerCase();
  return key === 'js' || key.endsWith('__js');
}
export function toolKind(name: string): 'command' | 'edit' | 'explore' | 'other' {
  const key = name.toLowerCase();
  if (isJavaScriptTool(name) || ['bash', 'shell', 'command_execution', 'bashoutput', 'js_reset'].includes(key)) return 'command';
  if (['write', 'edit', 'multiedit', 'notebookedit', 'applypatch', 'apply_patch', 'file_change', 'patch_apply'].includes(key)) return 'edit';
  if (['read', 'notebookread', 'grep', 'glob', 'ls', 'toolsearch', 'webfetch', 'websearch', 'web_search'].includes(key)) return 'explore';
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
  const path = input?.file_path || input?.notebook_path || input?.path || input?.changes?.[0]?.path;
  if (typeof path === 'string' && path) return { text: path.split('/').filter(Boolean).at(-1) || path, path };
  if (key === 'file_change' && input?.changes?.length) return { text: `${input.changes.length} files` };
  for (const field of ['description', 'pattern', 'query', 'url', 'skill']) {
    if (typeof input?.[field] === 'string') return { text: input[field] };
  }
  if (name.startsWith('mcp__')) return { text: name.slice(5).replace(/__/g, ' · ').replace(/_/g, ' ') };
  return { text: '' };
}
