/**
 * Monaco is bundled locally (no CDN) so the app works offline and inside the
 * webview CSP. Only the plain editor worker is wired up: Backtick shows diffs,
 * it does not run language services.
 */
import * as monaco from 'monaco-editor';
import EditorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker';

let configured = false;

export function setupMonaco(): typeof monaco {
  if (configured) return monaco;
  configured = true;

  self.MonacoEnvironment = {
    getWorker: () => new EditorWorker(),
  };

  monaco.editor.defineTheme('backtick', {
    base: 'vs-dark',
    inherit: true,
    rules: [],
    colors: {
      'editor.background': '#0a0a0a',
      'editorGutter.background': '#0a0a0a',
      'editor.lineHighlightBackground': '#141414',
      'editorLineNumber.foreground': '#4a4a4a',
      'editorLineNumber.activeForeground': '#9a9a9a',
      'diffEditor.insertedTextBackground': '#3fb95022',
      'diffEditor.removedTextBackground': '#f8514922',
      'diffEditor.insertedLineBackground': '#3fb95014',
      'diffEditor.removedLineBackground': '#f8514914',
      'editorOverviewRuler.border': '#00000000',
      'scrollbarSlider.background': '#38383866',
      'scrollbarSlider.hoverBackground': '#4a4a4a88',
    },
  });
  monaco.editor.setTheme('backtick');
  return monaco;
}

/** Best-effort language id from a file path, for syntax highlighting. */
export function languageForPath(path: string): string {
  const ext = path.split('.').pop()?.toLowerCase() ?? '';
  const map: Record<string, string> = {
    ts: 'typescript', tsx: 'typescript', js: 'javascript', jsx: 'javascript',
    mjs: 'javascript', cjs: 'javascript', json: 'json', jsonc: 'json',
    rs: 'rust', py: 'python', go: 'go', rb: 'ruby', java: 'java', kt: 'kotlin',
    swift: 'swift', c: 'c', h: 'c', cpp: 'cpp', cc: 'cpp', hpp: 'cpp',
    cs: 'csharp', php: 'php', sh: 'shell', bash: 'shell', zsh: 'shell',
    fish: 'shell', sql: 'sql', html: 'html', css: 'css', scss: 'scss',
    md: 'markdown', mdx: 'markdown', yml: 'yaml', yaml: 'yaml', toml: 'ini',
    ini: 'ini', xml: 'xml', dockerfile: 'dockerfile', graphql: 'graphql',
    vue: 'html', svelte: 'html', lua: 'lua', r: 'r', dart: 'dart', ex: 'elixir',
  };
  if (path.toLowerCase().endsWith('dockerfile')) return 'dockerfile';
  return map[ext] ?? 'plaintext';
}

export { monaco };
