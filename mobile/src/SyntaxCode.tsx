import React, { useMemo } from 'react';
import { ScrollView, Text, View } from 'react-native';
import Prism from 'prismjs';
import 'prismjs/components/prism-bash';
import 'prismjs/components/prism-clike';
import 'prismjs/components/prism-css';
import 'prismjs/components/prism-diff';
import 'prismjs/components/prism-go';
import 'prismjs/components/prism-java';
import 'prismjs/components/prism-javascript';
import 'prismjs/components/prism-json';
import 'prismjs/components/prism-jsx';
import 'prismjs/components/prism-markdown';
import 'prismjs/components/prism-python';
import 'prismjs/components/prism-ruby';
import 'prismjs/components/prism-rust';
import 'prismjs/components/prism-sql';
import 'prismjs/components/prism-swift';
import 'prismjs/components/prism-typescript';
import 'prismjs/components/prism-tsx';
import 'prismjs/components/prism-yaml';

const colors: Record<string, string> = {
  keyword: '#C678DD', string: '#98C379', char: '#98C379', attrValue: '#98C379',
  number: '#D19A66', boolean: '#D19A66', constant: '#D19A66',
  className: '#E5C07B', builtin: '#E5C07B', function: '#61AFEF',
  comment: '#5C6370', prolog: '#5C6370', operator: '#56B6C2',
  punctuation: '#ABB2BF', tag: '#E06C75', deleted: '#E06C75', inserted: '#98C379',
};
const extensions: Record<string, string> = { ts: 'typescript', tsx: 'tsx', js: 'javascript', jsx: 'jsx', mjs: 'javascript', json: 'json', swift: 'swift', py: 'python', rb: 'ruby', rs: 'rust', go: 'go', java: 'java', sh: 'bash', zsh: 'bash', css: 'css', html: 'markup', xml: 'markup', md: 'markdown', yml: 'yaml', yaml: 'yaml', sql: 'sql', diff: 'diff' };
export function languageForPath(path: string) { return extensions[path.split('.').at(-1)?.toLowerCase() || ''] || 'plain'; }
function renderTokens(tokens: Array<string | Prism.Token>, prefix = '', inherited = '#ABB2BF'): React.ReactNode[] {
  return tokens.map((token, index) => {
    const key = `${prefix}-${index}`;
    if (typeof token === 'string') return <Text key={key} style={{ color: inherited }}>{token}</Text>;
    const type = Array.isArray(token.alias) ? token.alias[0] : token.alias || token.type;
    const color = colors[String(type).replace(/-([a-z])/g, (_, x: string) => x.toUpperCase())] || colors[token.type] || inherited;
    const content = typeof token.content === 'string' ? token.content : Array.isArray(token.content) ? renderTokens(token.content, key, color) : renderTokens([token.content], key, color);
    return <Text key={key} style={{ color }}>{content}</Text>;
  });
}
export function SyntaxCode({ code, language, path, block = false }: { code: string; language?: string; path?: string; block?: boolean }) {
  const lang = (language || (path && languageForPath(path)) || 'plain').toLowerCase();
  const highlighted = useMemo(() => renderTokens(Prism.languages[lang] ? Prism.tokenize(code, Prism.languages[lang]) : [code]), [code, lang]);
  const text = <Text selectable style={{ fontFamily: 'JetBrainsMono', fontSize: 11, lineHeight: 18, color: '#ABB2BF' }}>{highlighted}</Text>;
  return block ? <View style={{ backgroundColor: '#252529', borderRadius: 7, marginBottom: 10, overflow: 'hidden' }}><ScrollView horizontal contentContainerStyle={{ padding: 10 }}>{text}</ScrollView></View> : text;
}
