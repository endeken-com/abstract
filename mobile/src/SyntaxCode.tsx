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
type SyntaxProps = { code: string; language?: string; path?: string };
type ColoredText = { text: string; color: string };
function flattenTokens(tokens: Array<string | Prism.Token>, inherited = '#ABB2BF'): ColoredText[] {
  return tokens.flatMap(token => {
    if (typeof token === 'string') return [{ text: token, color: inherited }];
    const type = Array.isArray(token.alias) ? token.alias[0] : token.alias || token.type;
    const color = colors[String(type).replace(/-([a-z])/g, (_, x: string) => x.toUpperCase())] || colors[token.type] || inherited;
    if (typeof token.content === 'string') return [{ text: token.content, color }];
    return flattenTokens(Array.isArray(token.content) ? token.content : [token.content], color);
  });
}
function tokenizeLines(lines: string[], language: string): ColoredText[][] {
  const result = lines.map(() => [] as ColoredText[]);
  if (!lines.length) return result;
  const code = lines.join('\n');
  const chunks = flattenTokens(Prism.languages[language] ? Prism.tokenize(code, Prism.languages[language]) : [code]);
  let line = 0;
  for (const chunk of chunks) {
    chunk.text.split('\n').forEach((text, index) => {
      if (index) line++;
      if (text && result[line]) result[line].push({ text, color: chunk.color });
    });
  }
  return result;
}
export function highlightDiffLines(lines: Array<{ kind: string; text: string; startsHunk?: boolean }>, path: string): ColoredText[][] {
  const language = languageForPath(path);
  const highlighted = lines.map(() => [] as ColoredText[]);
  let hunk: number[] = [];
  const flush = () => {
    const oldIndexes = hunk.filter(index => lines[index].kind !== '+');
    const newIndexes = hunk.filter(index => lines[index].kind !== '-');
    const oldTokens = tokenizeLines(oldIndexes.map(index => lines[index].text.slice(1)), language);
    const newTokens = tokenizeLines(newIndexes.map(index => lines[index].text.slice(1)), language);
    oldIndexes.forEach((index, position) => { highlighted[index] = oldTokens[position]; });
    newIndexes.forEach((index, position) => { highlighted[index] = newTokens[position]; });
    hunk = [];
  };
  lines.forEach((line, index) => {
    if (line.kind === '@' || line.startsHunk) flush();
    if (line.kind !== '@') hunk.push(index);
  });
  flush();
  return highlighted;
}
export function SyntaxTokens({ code, language, path }: SyntaxProps) {
  const lang = (language || (path && languageForPath(path)) || 'plain').toLowerCase();
  const highlighted = useMemo(() => renderTokens(Prism.languages[lang] ? Prism.tokenize(code, Prism.languages[lang]) : [code]), [code, lang]);
  return <>{highlighted}</>;
}
export function SyntaxCode({ code, language, path, block = false }: SyntaxProps & { block?: boolean }) {
  const text = <Text selectable style={{ fontFamily: 'JetBrainsMono', fontSize: 11, lineHeight: 18, color: '#ABB2BF' }}><SyntaxTokens code={code} language={language} path={path} /></Text>;
  return block ? <View style={{ backgroundColor: '#252529', borderRadius: 7, marginBottom: 10, overflow: 'hidden' }}><ScrollView horizontal contentContainerStyle={{ padding: 10 }}>{text}</ScrollView></View> : text;
}
