import React, { useEffect, useMemo, useRef, useState } from 'react';
import { BlurTargetView } from 'expo-blur';
import { ActivityIndicator, Alert, FlatList, KeyboardAvoidingView, Linking, Modal, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View, useWindowDimensions } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { MenuView } from '@react-native-menu/menu';
import * as Haptics from 'expo-haptics';
import Markdown from 'react-native-markdown-display';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { ProviderLogo, providerMenuImage } from './ProviderLogo';
import { ProgressiveBlur } from './ProgressiveBlur';
import { ScrollingTitle } from './ScrollingTitle';
import { remote } from './remote';
import { uuid } from './secure';
import { attachmentPayload, pickAttachments, type PickedAttachment } from './attachments';
import { chatTimeline, type ChatItem } from './chatTimeline';
import { IssueIcon, PullRequestIcon } from './PullRequestIcon';
import { FileIcon } from './FileIcon';
import { toolKind, toolSymbol } from './toolPresentation';
import { SwipeForward } from './SwipeForward';
import { useKeyboardHeight } from './useKeyboardVisible';
import { NativeSelect } from './NativeSelect';
import { SyntaxCode, highlightDiffLines } from './SyntaxCode';
import type { EditPreview } from './editPreview';
import type { PendingPermission, Session } from './types';

const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E', canvas = '#1E1E21', panel = '#252529', raised = '#2B2B30', border = 'rgba(255,255,255,0.075)';
const editStyles = StyleSheet.create({
  previews: { marginLeft: 22, gap: 8, paddingBottom: 6 },
  preview: { backgroundColor: panel, borderRadius: 6, overflow: 'hidden' },
  path: { color: muted, fontFamily: 'JetBrainsMono', fontSize: 10, paddingHorizontal: 10, paddingVertical: 7 },
  line: { color: ink, fontFamily: 'JetBrainsMono', fontSize: 11, lineHeight: 19, paddingHorizontal: 8 },
  number: { color: tertiary },
  plus: { color: '#4CC38A' },
  minus: { color: '#EF6461' },
  added: { backgroundColor: 'rgba(76,195,138,0.09)' },
  removed: { backgroundColor: 'rgba(239,100,97,0.09)' },
  gap: { color: tertiary, fontFamily: 'JetBrainsMono', fontSize: 11, lineHeight: 19, paddingHorizontal: 8 },
  more: { paddingHorizontal: 10, paddingVertical: 7 },
  moreText: { color: muted, fontFamily: 'Inter', fontSize: 11 },
});
const iconMap: Record<string, string> = { menu: 'sidebar.left', review: 'plusminus', files: 'doc.text', terminal: 'terminal', pr: 'arrow.triangle.pull', manage: 'ellipsis', attach: 'plus', send: 'arrow.up', stop: 'stop.fill', branch: 'arrow.triangle.branch', chevron: 'chevron.down', close: 'xmark' };
const androidIcons: Record<string, string> = { menu: 'menu', review: 'difference', files: 'description', terminal: 'terminal', pr: 'merge', manage: 'more_horiz', attach: 'add', send: 'arrow_upward', stop: 'stop', branch: 'account_tree', chevron: 'keyboard_arrow_down', close: 'close', 'arrow.down': 'arrow_downward', sparkles: 'auto_awesome', 'doc.text': 'description', 'doc.badge.plus': 'note_add', pencil: 'edit', magnifyingglass: 'search', globe: 'public', checklist: 'checklist', 'list.bullet.clipboard': 'assignment', 'person.2': 'group', 'book.closed': 'menu_book', 'questionmark.bubble': 'help', 'puzzlepiece.extension': 'extension', 'wrench.and.screwdriver': 'build', 'exclamationmark.triangle': 'warning' };
function Glyph({ name, size = 14, color = muted }: { name: string; size?: number; color?: string }) { return <SymbolView name={{ ios: iconMap[name] || name, android: androidIcons[name] || (name === 'checkmark' ? 'check' : name), web: androidIcons[name] || (name === 'checkmark' ? 'check' : name) } as any} size={size} tintColor={color} style={{ width: size, height: size }} />; }
function Chip({ icon, label, onPress, active }: { icon?: string; label?: string; onPress: () => void; active?: boolean }) { return <Pressable accessibilityRole="button" accessibilityLabel={label} onPress={() => { Haptics.selectionAsync().catch(() => {}); onPress(); }} style={[s.chip, active && s.chipActive]}>{icon && <Glyph name={icon} size={14} color={active ? ink : muted} />}{label && <Text numberOfLines={1} style={[s.chipLabel, active && { color: ink }]}>{label}</Text>}</Pressable>; }
function ToolbarAction({ label, onPress, children }: { label: string; onPress: () => void; children: React.ReactNode }) {
  return <Pressable accessibilityRole="button" accessibilityLabel={label} onPress={onPress} style={chrome.toolbarButton}>{children}</Pressable>;
}
type SlashChoiceKind = 'agent' | 'model' | 'effort' | 'mode';
type SlashItem = { id: string; title: string; detail?: string; checked?: boolean; next?: boolean; onPress: () => void };
function SlashPopup({ title, items, maxHeight, onBack }: { title: string; items: SlashItem[]; maxHeight: number; onBack?: () => void }) {
  return <View style={[slashStyles.popup, { maxHeight }]}>
    <View style={slashStyles.header}>{onBack && <Pressable accessibilityRole="button" accessibilityLabel="Back to commands" onPress={onBack} style={slashStyles.back}><Text style={slashStyles.backText}>‹</Text></Pressable>}<Text style={slashStyles.heading}>{title}</Text><Text style={slashStyles.count}>{items.length}</Text></View>
    <ScrollView style={{ maxHeight: maxHeight - 39 }} keyboardShouldPersistTaps="always" showsVerticalScrollIndicator={false} contentContainerStyle={slashStyles.list}>
      {items.length ? items.map(item => <Pressable key={item.id} accessibilityRole="button" accessibilityLabel={item.title} accessibilityState={{ selected: !!item.checked }} onPress={() => { Haptics.selectionAsync().catch(() => {}); item.onPress(); }} style={({ pressed }) => [slashStyles.row, pressed && slashStyles.rowPressed]}>
        <View style={slashStyles.rowText}><Text numberOfLines={1} style={slashStyles.command}>{item.title}</Text>{item.detail ? <Text numberOfLines={1} style={slashStyles.detail}>{item.detail}</Text> : null}</View>
        {item.checked ? <Glyph name="checkmark" size={15} color={ink} /> : item.next ? <Text style={slashStyles.next}>›</Text> : null}
      </Pressable>) : <Text style={slashStyles.empty}>No matching commands</Text>}
    </ScrollView>
  </View>;
}
const slashStyles = StyleSheet.create({
  popup: { position: 'absolute', bottom: '100%', left: 10, right: 10, marginBottom: 8, zIndex: 10, backgroundColor: '#303035', borderRadius: 13, borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.2)', overflow: 'hidden', shadowColor: '#000', shadowOpacity: 0.28, shadowRadius: 16, shadowOffset: { width: 0, height: 8 }, elevation: 12 },
  header: { minHeight: 39, flexDirection: 'row', alignItems: 'center', gap: 7, paddingHorizontal: 13, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  back: { width: 26, height: 29, alignItems: 'center', justifyContent: 'center' },
  backText: { color: ink, fontFamily: 'Inter', fontSize: 25, lineHeight: 27 },
  heading: { flex: 1, color: muted, fontFamily: 'Inter', fontSize: 10, fontWeight: '700', letterSpacing: 1 },
  count: { color: tertiary, fontFamily: 'JetBrainsMono', fontSize: 10 },
  list: { padding: 5 },
  row: { minHeight: 51, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 10, borderRadius: 8 },
  rowPressed: { backgroundColor: '#414148' },
  rowText: { flex: 1, minWidth: 0, gap: 2 },
  command: { color: ink, fontFamily: 'JetBrainsMono', fontSize: 13 },
  detail: { color: muted, fontFamily: 'Inter', fontSize: 11 },
  next: { color: tertiary, fontFamily: 'Inter', fontSize: 22 },
  empty: { color: muted, fontFamily: 'Inter', fontSize: 12, paddingHorizontal: 10, paddingVertical: 16 },
});
type LinkKind = 'issue' | 'linkPr';
type LinkItem = { number: number; title: string; url: string; body?: string; state?: string; isDraft?: boolean; baseRefName?: string; headRefName?: string };
function LinkPickerSheet({ kind, query, setQuery, results, loading, search, select, close }: { kind: LinkKind | null; query: string; setQuery: (value: string) => void; results: LinkItem[]; loading: boolean; search: () => void; select: (item: LinkItem) => void; close: () => void }) {
  const ios = Platform.OS === 'ios';
  return <Modal visible={kind !== null} animationType="slide" presentationStyle={ios ? 'pageSheet' : 'overFullScreen'} transparent={!ios} onRequestClose={close}>
    <KeyboardAvoidingView style={ios ? s.sheetRoot : s.sheetBackdrop} behavior={ios ? 'padding' : undefined}>
      {!ios && <Pressable style={StyleSheet.absoluteFill} onPress={close} accessibilityLabel="Close search" />}
      <SafeAreaView edges={['bottom']} style={[s.sheetPanel, ios && { flex: 1, maxHeight: '100%' }]}>
        <View style={s.sheetHandle} />
        <View style={s.sheetHeader}><Text style={s.sheetTitle}>{kind === 'issue' ? 'Find an issue' : 'Find a pull request'}</Text><Pressable accessibilityRole="button" accessibilityLabel="Close" onPress={close} style={s.sheetClose}><Glyph name="close" size={17} color={ink} /></Pressable></View>
        <View style={s.sheetSearch}><Glyph name="magnifyingglass" size={17} color={tertiary} /><TextInput autoFocus value={query} onChangeText={setQuery} onSubmitEditing={search} returnKeyType="search" autoCapitalize="none" placeholder={kind === 'issue' ? 'Search issues' : 'Search pull requests'} placeholderTextColor={tertiary} style={s.sheetInput} /><Pressable accessibilityRole="button" accessibilityLabel="Search" onPress={search} style={s.sheetSearchButton}><Text style={s.sheetSearchButtonText}>Search</Text></Pressable></View>
        <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={s.sheetResults}>{loading ? <ActivityIndicator color={muted} style={{ padding: 20 }} /> : results.length ? results.map(item => <Pressable accessibilityRole="button" key={item.url} onPress={() => select(item)} style={s.sheetResult}><Text style={s.sheetReference}>#{item.number}</Text><View style={{ flex: 1 }}><Text numberOfLines={2} style={s.sheetResultTitle}>{item.title}</Text><Text style={s.sheetResultMeta}>{item.isDraft ? 'Draft' : item.state || ''}</Text></View><Glyph name="chevron" size={14} color={tertiary} /></Pressable>) : <Text style={s.sheetEmpty}>No results</Text>}</ScrollView>
      </SafeAreaView>
    </KeyboardAvoidingView>
  </Modal>;
}
function PermissionCard({ sessionId, request }: { sessionId: string; request: PendingPermission }) {
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const questions = request.toolName === 'AskUserQuestion' ? request.input?.questions || [] : [];
  const submit = (allow: boolean) => remote.request(questions.length && allow ? 'answerQuestion' : 'answer', questions.length && allow ? { sessionId, requestId: request.requestId, answers } : { sessionId, requestId: request.requestId, allow }).catch(e => Alert.alert('Abstract', String(e)));
  return <View style={s.permission}><Text style={s.permissionTitle}>{questions.length ? 'Question from agent' : `Permission · ${request.toolName}`}</Text>{questions.length ? questions.map((q: any) => <View key={q.question}><Text style={s.prose}>{q.question}</Text>{q.options?.map((o: any) => <Chip key={o.label} label={o.label} active={answers[q.question] === o.label} onPress={() => setAnswers({ ...answers, [q.question]: o.label })} />)}<TextInput value={answers[q.question] || ''} onChangeText={v => setAnswers({ ...answers, [q.question]: v })} placeholder="Your answer" placeholderTextColor={tertiary} style={s.permissionInput} /></View>) : <Text style={s.toolDetail}>{JSON.stringify(request.input, null, 2)}</Text>}<View style={s.permissionActions}><Chip label={questions.length ? 'Send answers' : 'Allow'} onPress={() => submit(true)} /><Chip label={questions.length ? 'Skip' : 'Deny'} onPress={() => submit(false)} /></View></View>;
}
function ToolEditPreview({ edit }: { edit: EditPreview }) {
  const [showAll, setShowAll] = useState(false);
  const highlighted = useMemo(() => highlightDiffLines(edit.lines, edit.path), [edit]);
  const shown = showAll ? edit.lines : edit.lines.slice(0, 14);
  return <View style={editStyles.preview}>
    {edit.path ? <Text numberOfLines={1} style={editStyles.path}>{edit.path}</Text> : null}
    <ScrollView horizontal><View>{shown.map((line, index) => <React.Fragment key={index}>
      {index > 0 && line.startsHunk && <Text style={editStyles.gap}>⋯</Text>}
      <Text style={[editStyles.line, line.kind === '+' && editStyles.added, line.kind === '-' && editStyles.removed]}>
        <Text style={editStyles.number}>{String(line.next ?? line.old ?? '').padStart(4)} </Text>
        <Text style={line.kind === '+' ? editStyles.plus : line.kind === '-' ? editStyles.minus : editStyles.number}>{line.kind === '-' ? '−' : line.kind}</Text>
        {highlighted[index].map((part, partIndex) => <Text key={partIndex} style={{ color: part.color }}>{part.text}</Text>)}
      </Text>
    </React.Fragment>)}</View></ScrollView>
    {edit.lines.length > shown.length && <Pressable onPress={() => setShowAll(true)} style={editStyles.more}><Text style={editStyles.moreText}>Show {edit.lines.length - shown.length} more lines</Text></Pressable>}
  </View>;
}
function TranscriptRow({ row }: { row: ChatItem }) {
  const [expanded, setExpanded] = useState(false);
  if (row.kind === 'thinking') return <View style={s.thinkingRow}><Text style={s.thinkingLabel}>{row.pending ? 'Thinking' : 'Thought'}</Text><Text style={s.thinkingText}>{row.text.trim()}</Text></View>;
  if (row.kind === 'turn') return <View style={s.turnRow}><View style={s.turnRule} /><Text style={s.thinkingLabel}>{duration(row.durationMs || 0)}</Text><View style={s.turnRule} /></View>;
  if (row.kind === 'user') return <View style={s.userRow}><View style={s.userBubble}><Text style={s.prose}>{row.text}</Text></View></View>;
  if (row.kind === 'tool') return <View><Pressable accessibilityRole="button" accessibilityLabel={`${row.text} ${row.target || ''}`} onPress={() => setExpanded(!expanded)} style={s.toolRow}>
    <View style={s.toolIcon}>{row.failed ? <Glyph name="exclamationmark.triangle" size={15} color="#EF6461" /> : row.path && toolKind(row.toolName || '') === 'edit' ? <FileIcon path={row.path} size={17} /> : <Glyph name={toolSymbol(row.toolName || '')} size={15} color={tertiary} />}</View>
    <Text style={s.toolVerb}>{row.text}</Text>{!!row.target && <Text numberOfLines={1} style={s.toolLabel}>{row.target}</Text>}
    {(row.additions !== undefined || row.deletions !== undefined) && <Text style={{ fontFamily: 'JetBrainsMono', fontSize: 10, flexShrink: 0 }}><Text style={{ color: '#4CC38A' }}>+{row.additions || 0}</Text><Text style={{ color: tertiary }}> </Text><Text style={{ color: '#EF6461' }}>−{row.deletions || 0}</Text></Text>}
    {row.failed && <Text style={s.toolFailed}>Failed</Text>}{row.pending && <Text style={s.toolPending}>Working</Text>}
    {(!!row.detail || !!row.edits?.length) && <Glyph name={expanded ? 'chevron.up' : 'chevron.down'} size={10} color={tertiary} />}
  </Pressable>{expanded && !!row.edits?.length && <View style={editStyles.previews}>{row.edits.map((edit, index) => <ToolEditPreview key={`${edit.path}-${index}`} edit={edit} />)}</View>}{expanded && !!row.detail && (!row.edits?.length || row.failed) && <Text selectable style={s.toolDetail}>{row.detail}</Text>}</View>;
  if (row.kind === 'error') return <Text style={[s.prose, { color: '#F08A84' }]}>{row.text}</Text>;
  return <Markdown style={markdownStyles} rules={codeRules}>{row.text}</Markdown>;
}
const codeRules = {
  fence: (node: any) => <SyntaxCode key={node.key} code={String(node.content || '').replace(/\n$/, '')} language={node.sourceInfo?.trim().split(/\s+/)[0]} block />,
  code_block: (node: any) => <SyntaxCode key={node.key} code={String(node.content || '').replace(/\n$/, '')} block />,
};
function duration(ms: number) {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return seconds % 60 ? `${minutes}m ${seconds % 60}s` : `${minutes}m`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}
function DotLoader() {
  const [step, setStep] = useState(0);
  useEffect(() => { const timer = setInterval(() => setStep(value => (value + 1) % 6), 158); return () => clearInterval(timer); }, []);
  const order = [0, 2, 4, 5, 3, 1];
  const levels = [1, 0.7, 0.45, 0.28, 0.16, 0.16];
  return <View style={{ width: 14, height: 14, alignItems: 'center', justifyContent: 'center' }}><View style={s.dotGrid}>{Array.from({ length: 6 }, (_, index) => <View key={index} style={[s.dot, { opacity: levels[(step - order.indexOf(index) + 6) % 6] }]} />)}</View></View>;
}
function WorkingStatus({ label, startedAt }: { label: string; startedAt?: number }) {
  const [now, setNow] = useState(Date.now());
  const fallback = useRef(Date.now());
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  const started = startedAt == null ? fallback.current : (startedAt + 978307200) * 1000;
  return <View style={s.working}><DotLoader /><Text style={s.workingLabel}>{label}</Text><Text style={s.workingDuration}>{duration(now - started)}</Text></View>;
}
type TranscriptGroupItem = { id: string; kind: 'group'; groupKind: 'command' | 'explore'; rows: ChatItem[] };
function groupToolRows(rows: ChatItem[]): Array<ChatItem | TranscriptGroupItem> {
  const result: Array<ChatItem | TranscriptGroupItem> = [];
  for (let index = 0; index < rows.length;) {
    const first = rows[index];
    const kind = first.kind === 'tool' ? toolKind(first.toolName || '') : 'other';
    if (kind === 'command' || kind === 'explore') {
      let end = index + 1;
      while (end < rows.length && rows[end].kind === 'tool' && toolKind(rows[end].toolName || '') === kind && (kind !== 'command' || end - index < 8)) end++;
      if (end - index > 1) {
        result.push({ id: `group-${first.id}`, kind: 'group', groupKind: kind, rows: rows.slice(index, end) });
        index = end;
        continue;
      }
    }
    result.push(first);
    index++;
  }
  return result;
}
function ToolGroupRow({ group }: { group: TranscriptGroupItem }) {
  const [expanded, setExpanded] = useState(group.groupKind === 'command');
  const pending = group.rows.some(row => row.pending);
  const failed = group.rows.filter(row => row.failed).length;
  const summary = group.groupKind === 'command' ? `${group.rows.length} commands` : (() => {
    const reads = group.rows.filter(row => ['read', 'notebookread'].includes((row.toolName || '').toLowerCase()));
    const files = new Set(reads.map(row => row.path || row.id)).size;
    const searches = group.rows.filter(row => ['grep', 'glob', 'ls', 'toolsearch'].includes((row.toolName || '').toLowerCase())).length;
    const web = group.rows.filter(row => ['websearch', 'web_search'].includes((row.toolName || '').toLowerCase())).length;
    const pages = group.rows.filter(row => (row.toolName || '').toLowerCase() === 'webfetch').length;
    const other = group.rows.length - reads.length - searches - web - pages;
    return [files && `${files} file${files === 1 ? '' : 's'}`, searches && `${searches} search${searches === 1 ? '' : 'es'}`, web && `${web} web search${web === 1 ? '' : 'es'}`, pages && `${pages} page${pages === 1 ? '' : 's'}`, other > 0 && `${other} lookup${other === 1 ? '' : 's'}`].filter(Boolean).join(', ');
  })();
  return <View><Pressable accessibilityRole="button" accessibilityLabel={`${pending ? 'Running' : 'Ran'} ${summary}`} onPress={() => setExpanded(!expanded)} style={s.toolRow}>
    <View style={s.toolIcon}><Glyph name={group.groupKind === 'command' ? 'terminal' : 'magnifyingglass'} size={15} color={tertiary} /></View>
    <Text style={s.toolVerb}>{group.groupKind === 'command' ? pending ? 'Running' : 'Ran' : pending ? 'Exploring' : 'Explored'}</Text>
    <Text style={s.toolLabel}>{summary}</Text>{failed > 0 && <Text style={s.toolFailed}>{failed} failed</Text>}
    <Glyph name={expanded ? 'chevron.up' : 'chevron.down'} size={10} color={tertiary} />
  </Pressable>{expanded && <View style={{ marginLeft: 9, paddingLeft: 10, borderLeftWidth: 1, borderLeftColor: border }}>{group.rows.map(row => <TranscriptRow key={row.id} row={row} />)}</View>}</View>;
}
const renderTranscriptItem = ({ item }: { item: ChatItem | TranscriptGroupItem }) => item.kind === 'group' ? <ToolGroupRow group={item} /> : <TranscriptRow row={item} />;
const transcriptKey = (row: ChatItem | TranscriptGroupItem) => row.id;
export function ChatWorkspace({ route, navigation }: any) {
  const [, force] = useState(0);
  useEffect(() => remote.subscribe(() => force(x => x + 1)), []);
  const id = route.params.sessionId as string;
  const chat = remote.snapshot?.sessions.find(x => x.id === id);
  const pr = remote.snapshot?.pullRequests?.[id];
  const [message, setMessage] = useState('');
  const [syncing, setSyncing] = useState(false);
  const keyboardHeight = useKeyboardHeight();
  const safeArea = useSafeAreaInsets();
  const { width: windowWidth, height: windowHeight } = useWindowDimensions();
  const blurTarget = useRef<View>(null);
  const [previewingMarkdown, setPreviewingMarkdown] = useState(false);
  const [atBottom, setAtBottom] = useState(true);
  const [attachments, setAttachments] = useState<PickedAttachment[]>([]);
  const [menu, setMenu] = useState<'manage' | null>(null);
  const [slashChoosing, setSlashChoosing] = useState<SlashChoiceKind | null>(null);
  const [linkSheet, setLinkSheet] = useState<LinkKind | null>(null);
  const [linkQuery, setLinkQuery] = useState('');
  const [linkResults, setLinkResults] = useState<LinkItem[]>([]);
  const [linkLoading, setLinkLoading] = useState(false);
  const [rename, setRename] = useState('');
  const [diff, setDiff] = useState({ files: 0, added: 0, removed: 0 });
  const [bottomPanelHeight, setBottomPanelHeight] = useState(180);
  const scroll = useRef<FlatList<ChatItem | TranscriptGroupItem>>(null);
  const following = useRef(true);
  const userDragged = useRef(false);
  const mayLoadOlder = useRef(false);
  const lines = remote.lines[id] || [];
  const hasOlder = remote.hasOlder(id);
  const loadingHistory = remote.loadingHistory.has(id);
  const rows = useMemo(() => chatTimeline(lines, id), [id, lines]);
  const displayRows = useMemo(() => groupToolRows(rows), [rows]);
  const transcriptRows = useMemo(() => chat?.prompt && !lines.length
    ? [{ id: 'prompt', kind: 'user' as const, text: chat.prompt }, ...displayRows] : displayRows, [chat?.prompt, lines.length, displayRows]);
  const lastRow = rows.at(-1);
  const showWorking = chat?.status === 'running' || chat?.status === 'provisioning';
  const showWorkingRow = showWorking && !(lastRow?.pending && ['tool', 'prose', 'thinking'].includes(lastRow.kind));
  const workingLabel = lastRow && (lastRow.kind === 'thinking' || (lastRow.kind === 'tool' && !lastRow.pending)) ? 'Thinking…' : 'Working…';
  const pendingPermissions = remote.snapshot?.pendingPermissions?.[id];
  const turnStartedAt = remote.snapshot?.turnStartedAt?.[id] ?? chat?.lastEventAt ?? undefined;
  const transcriptFooter = useMemo(() => <View style={s.transcriptFooter}>{(pendingPermissions || []).map(request => <PermissionCard key={request.requestId} sessionId={id} request={request} />)}{syncing && <Text style={s.thinkingLabel}>Syncing chat from Mac…</Text>}{showWorkingRow && <WorkingStatus label={workingLabel} startedAt={turnStartedAt} />}</View>, [pendingPermissions, id, syncing, showWorkingRow, workingLabel, turnStartedAt]);
  const loadEarlier = React.useCallback(() => {
    mayLoadOlder.current = false;
    following.current = false;
    userDragged.current = true;
    setAtBottom(false);
    remote.loadOlder(id).catch(() => {});
  }, [id]);
  const onTranscriptScroll = React.useCallback((event: any) => {
    const { contentOffset, layoutMeasurement, contentSize } = event.nativeEvent;
    const next = contentOffset.y + layoutMeasurement.height >= contentSize.height - 80;
    // Layout changes during replay can move the visible offset away from the
    // end even though the reader has not scrolled. Keep following until a drag.
    if (!userDragged.current && !next) return;
    following.current = next;
    setAtBottom(previous => previous === next ? previous : next);
    if (mayLoadOlder.current && contentOffset.y < 180 && remote.hasOlder(id)) loadEarlier();
  }, [id, loadEarlier]);
  const onTranscriptSize = React.useCallback(() => { if (following.current) scroll.current?.scrollToEnd({ animated: false }); }, []);
  const onTranscriptDrag = React.useCallback(() => { userDragged.current = true; mayLoadOlder.current = true; }, []);
  useEffect(() => {
    following.current = true;
    userDragged.current = false;
    mayLoadOlder.current = false;
    setAtBottom(true);
    scroll.current?.scrollToEnd({ animated: false });
  }, [id]);
  useEffect(() => {
    if (!chat) return;
    const chatRoot = chat.worktreePath || remote.snapshot?.projects.find(x => x.id === chat.projectId)?.rootPath || '';
    const request = (name: string, args: Record<string, unknown> = {}) => remote.request(name, { sessionId: id, ...args }).catch(e => Alert.alert('Abstract', String(e)));
    navigation.setOptions({
      headerTransparent: true,
      headerStyle: { backgroundColor: 'transparent' },
      headerBackground: () => <ProgressiveBlur edge="top" blurTarget={blurTarget} />,
      headerTitle: () => <ScrollingTitle title={chat.name} provider={chat.providerId} width={Math.max(72, Math.min(192, windowWidth - 245))} />,
      headerLeft: () => <ToolbarAction label="Open sidebar" onPress={() => navigation.popTo('Sidebar', { selectedChat: id })}><Glyph name="menu" size={19} color={ink} /></ToolbarAction>,
      headerRight: () => <View style={chrome.nativeActions}>
        <ToolbarAction label="Review changes" onPress={() => navigation.navigate('Review', { sessionId: id })}><Glyph name="review" size={17} color={muted} /></ToolbarAction>
        <ToolbarAction label="Files" onPress={() => navigation.navigate('Files', { root: chatRoot, sessionId: id })}><Glyph name="files" size={18} /></ToolbarAction>
        <ToolbarAction label="Pull request" onPress={() => navigation.navigate('PullRequest', { sessionId: id })}><PullRequestIcon pr={pr} size={17} color={muted} /></ToolbarAction>
        <MenuView actions={[
          { id: 'terminal', title: 'Terminal', image: Platform.OS === 'ios' ? 'terminal' : undefined },
          { id: 'rename', title: 'Rename chat', image: Platform.OS === 'ios' ? 'pencil' : undefined },
          { id: 'resume', title: 'Resume agent', image: Platform.OS === 'ios' ? 'arrow.clockwise' : undefined },
          { id: 'archive', title: chat.archivedAt ? 'Unarchive chat' : 'Archive chat', image: Platform.OS === 'ios' ? 'archivebox' : undefined },
          { id: 'delete', title: 'Delete chat', attributes: { destructive: true }, image: Platform.OS === 'ios' ? 'trash' : undefined },
        ]} onPressAction={({ nativeEvent }) => {
          switch (nativeEvent.event) {
            case 'terminal': navigation.navigate('Terminal', { root: chatRoot, sessionId: id }); break;
            case 'rename': if (Platform.OS === 'ios') Alert.prompt('Rename chat', '', name => name.trim() && request('rename', { name: name.trim() }), 'plain-text', chat.name); else { setRename(chat.name); setMenu('manage'); } break;
            case 'resume': request('resume'); break;
            case 'archive': request('setArchived', { archived: !chat.archivedAt }); break;
            case 'delete': Alert.alert('Delete chat?', chat.name, [{ text: 'Cancel' }, { text: 'Keep worktree', onPress: () => request('deleteChat', { removeWorktree: false }) }, { text: 'Delete worktree too', style: 'destructive', onPress: () => request('deleteChat', { removeWorktree: true }) }]); break;
          }
        }}><View style={chrome.toolbarButton} accessibilityLabel="More chat actions"><Glyph name="manage" size={20} /></View></MenuView>
      </View>,
    });
  }, [navigation, id, windowWidth, chat?.name, chat?.providerId, chat?.archivedAt, chat?.worktreePath, pr?.state, pr?.isDraft]);
  useEffect(() => {
    if (remote.status !== 'online') { setSyncing(false); return; }
    let active = true;
    const retries: Array<ReturnType<typeof setTimeout>> = [];
    setSyncing(true);
    remote.subscribeChat(id).then(() => {
      if (active) setSyncing(false);
      if (!active || userDragged.current) return;
      following.current = true;
      setAtBottom(true);
      // The list's content size callback follows later row measurements.
      scroll.current?.scrollToEnd({ animated: false });
      retries.push(setTimeout(() => { if (active && !userDragged.current) scroll.current?.scrollToEnd({ animated: false }); }, 250));
    }).catch(() => { if (active) setSyncing(false); });
    return () => {
      active = false;
      retries.forEach(clearTimeout);
      remote.unsubscribeChat(id).catch(() => {});
    };
  }, [id, remote.status]);
  useEffect(() => { if (!chat) return; const root = chat.worktreePath || remote.snapshot?.projects.find(x => x.id === chat.projectId)?.rootPath; if (!root || remote.status !== 'online') { setDiff({ files: 0, added: 0, removed: 0 }); return; } let active = true; const refresh = () => remote.exec(root, ['diff', 'HEAD', '--numstat']).then(result => { if (!active) return; const counts = result.stdout.split('\n').filter(line => line.includes('\t')).reduce((n, line) => { const [a, d] = line.split('\t'); return { files: n.files + 1, added: n.added + (Number(a) || 0), removed: n.removed + (Number(d) || 0) }; }, { files: 0, added: 0, removed: 0 }); setDiff(counts); }).catch(() => {}); const timer = setTimeout(refresh, 400); const interval = setInterval(refresh, 15000); return () => { active = false; clearTimeout(timer); clearInterval(interval); }; }, [id, chat?.status, chat?.worktreePath, chat?.projectId, remote.status]);
  if (!chat) return <View style={s.waiting}><Text style={s.faint}>Waiting for this chat on the Mac…</Text></View>;
  const root = chat.worktreePath || remote.snapshot?.projects.find(x => x.id === chat.projectId)?.rootPath || '';
  const worktreeLabel = chat.branch || chat.worktreePath?.split('/').at(-1) || (chat.projectId ? remote.snapshot?.projects.find(x => x.id === chat.projectId)?.name : null) || 'No worktree';
  const worktreeKind = chat.worktreePath ? 'WORKTREE' : chat.projectId ? 'PROJECT' : 'STANDALONE';
  const catalog = remote.snapshot?.modelCatalogs?.[chat.providerId];
  const modelOption = catalog?.models.find(x => x.id === chat.model) || catalog?.versions.find(x => x.id === chat.model);
  const defaultModelLabel = remote.snapshot?.defaultModelNames?.[chat.providerId] || catalog?.accountDefault?.label;
  const modelLabel = chat.model ? modelOption?.label || chat.model : defaultModelLabel || 'Default model';
  const effortLabel = (chat.effort || modelOption?.defaultEffort || catalog?.accountDefault?.defaultEffort || 'Default effort').replace(/^./, x => x.toUpperCase());
  const providerLabel = { codex: 'Codex', claude: 'Claude Code', opencode: 'OpenCode' }[chat.providerId] || chat.providerId;
  const policyLabel = { ask: 'Ask before acting', 'auto-edits': 'Accept edits', bypass: 'Full autonomy' }[chat.permissionPolicy];
  const act = (name: string, args: Record<string, unknown> = {}) => remote.request(name, { sessionId: id, ...args }).catch(e => Alert.alert('Abstract', String(e)));
  const send = async () => { if (!message.trim() && !attachments.length) return; if (/^\/[a-z]+$/i.test(message.trim()) && runSlash(message.trim().slice(1))) return; try { if (attachments.length) await remote.request('sendAttachments', { sessionId: id, text: message, ...attachmentPayload(attachments) }); else await remote.request('send', { sessionId: id, text: message }); setMessage(''); setAttachments([]); setPreviewingMarkdown(false); } catch (e) { Alert.alert('Could not send', String(e)); } };
  const searchLinks = async (source: LinkKind, query: string) => {
    if (!root) return;
    setLinkLoading(true);
    try {
      const kind = source === 'issue' ? 'issue' : 'pr';
      const fields = source === 'issue' ? 'number,title,url,state,body' : 'number,title,url,state,body,isDraft,baseRefName,headRefName';
      const args = [kind, 'list', '--limit', '30', '--json', fields, '--state', query.trim() ? 'all' : 'open', ...(query.trim() ? ['--search', query.trim()] : [])];
      const reply = await remote.request('exec', { command: 'gh', args, cwd: root });
      const output = reply.exec?._0;
      if (output?.code !== 0) throw Error(output?.stderr || 'Could not search GitHub.');
      setLinkResults(JSON.parse(output.stdout || '[]'));
    } catch (error) { Alert.alert('GitHub', String(error)); setLinkResults([]); }
    finally { setLinkLoading(false); }
  };
  const openLinks = (source: LinkKind) => { setLinkSheet(source); setLinkQuery(''); setLinkResults([]); searchLinks(source, ''); };
  const attachLink = (item: (typeof linkResults)[number]) => {
    if (attachments.some(x => x.url === item.url)) { setLinkSheet(null); return; }
    setAttachments([...attachments, { id: uuid(), kind: linkSheet === 'issue' ? 'githubIssue' : 'pullRequest', title: item.title,
      path: null, reference: `#${item.number}`, url: item.url, body: item.body?.slice(0, 12_000) || null,
      details: [item.state ? `State: ${item.isDraft ? 'Draft' : item.state}` : '', item.baseRefName ? `Base: ${item.baseRefName}` : '', item.headRefName ? `Head: ${item.headRefName}` : ''].filter(Boolean), data: '', size: 0 }]);
    setLinkSheet(null);
  };
  const slashCommands = [
    ['agent', 'Switch this chat to another agent'], ['model', 'Choose the model'],
    ['effort', 'Choose the reasoning effort'], ['mode', 'Choose how much the agent may do without asking'],
    ...(chat.status === 'running' ? [['stop', 'Stop the agent']] : []),
    ['diff', 'Review the changes'], ['rename', 'Rename this chat'], ['attach', 'Attach files or a folder']
  ];
  const slashQuery = message.startsWith('/') && !/\s/.test(message) ? message.slice(1).toLowerCase() : null;
  const slashMatches = slashQuery == null ? [] : slashCommands.filter(([command]) => command.includes(slashQuery)).sort(([a], [b]) => Number(b === slashQuery) - Number(a === slashQuery));
  const runSlash = (command: string) => {
    switch (command) {
      case 'agent': case 'model': case 'effort': case 'mode': setSlashChoosing(command); return true;
      case 'stop': act('stop'); break;
      case 'diff': navigation.navigate('Review', { sessionId: id }); break;
      case 'rename': setMenu('manage'); break;
      case 'attach': pickAttachments(attachments).then(setAttachments).catch(e => Alert.alert('Attachment', String(e))); break;
      default: return false;
    }
    setMessage('');
    setSlashChoosing(null);
    return true;
  };
  const providerChoices = (remote.snapshot?.providers || []).map(value => ({ id: value, title: ({ codex: 'Codex', claude: 'Claude Code', opencode: 'OpenCode' } as Record<string, string>)[value] || value, selected: value === chat.providerId, image: Platform.OS === 'ios' ? providerMenuImage(value) : undefined }));
  const modelChoices = [{ id: '', title: defaultModelLabel ? `Default (${defaultModelLabel})` : 'Default model', selected: !chat.model }, ...(catalog?.models || []).map(value => ({ id: value.id, title: value.label, selected: value.id === chat.model }))];
  const effortChoices = [{ id: '', title: 'Default effort', selected: !chat.effort }, ...(modelOption?.efforts || catalog?.accountDefault?.efforts || []).map(value => ({ id: value, title: value.replace(/^./, x => x.toUpperCase()), selected: value === chat.effort }))];
  const policyChoices = ([['ask', 'Ask before acting'], ['auto-edits', 'Accept edits'], ['bypass', 'Full autonomy']] as const).map(([id, title]) => ({ id, title, selected: id === chat.permissionPolicy }));
  const applySlashChoice = (action: () => void) => { action(); setMessage(''); setSlashChoosing(null); };
  const slashChoices: SlashItem[] = slashChoosing === 'agent' ? providerChoices.map(choice => ({ id: choice.id, title: choice.title, checked: choice.selected, onPress: () => applySlashChoice(() => act('setAgent', { providerId: choice.id, model: null, effort: null })) }))
    : slashChoosing === 'model' ? modelChoices.map(choice => ({ id: choice.id || 'default', title: choice.title, checked: choice.selected, onPress: () => applySlashChoice(() => act('setAgent', { providerId: chat.providerId, model: choice.id || null, effort: null })) }))
    : slashChoosing === 'effort' ? effortChoices.map(choice => ({ id: choice.id || 'default', title: choice.title, checked: choice.selected, onPress: () => applySlashChoice(() => act('setAgent', { providerId: chat.providerId, model: chat.model, effort: choice.id || null })) }))
    : slashChoosing === 'mode' ? policyChoices.map(choice => ({ id: choice.id, title: choice.title, checked: choice.selected, onPress: () => applySlashChoice(() => act('setPolicy', { policy: choice.id })) })) : [];
  const slashItems: SlashItem[] = slashChoosing ? slashChoices : slashMatches.map(([command, detail]) => ({ id: command, title: `/${command}`, detail, next: ['agent', 'model', 'effort', 'mode'].includes(command), onPress: () => { runSlash(command); } }));
  const slashPopupOpen = !previewingMarkdown && (slashChoosing !== null || slashQuery !== null);
  const keyboardOffset = Platform.OS === 'ios' ? keyboardHeight : 0;
  const slashPopupHeight = Math.max(150, Math.min(365, windowHeight - keyboardOffset - bottomPanelHeight - safeArea.top - 22));
  return <SafeAreaView edges={['left', 'right']} style={s.root}>
    <SwipeForward onSwipe={() => navigation.navigate('Review', { sessionId: id })} onBack={() => navigation.goBack()}><BlurTargetView ref={blurTarget} style={{ flex: 1 }}><FlatList ref={scroll} style={s.transcript} contentInsetAdjustmentBehavior="automatic" contentContainerStyle={[s.transcriptContent, { paddingBottom: bottomPanelHeight + keyboardOffset + 20 }]} data={transcriptRows} keyExtractor={transcriptKey} renderItem={renderTranscriptItem} initialNumToRender={14} maxToRenderPerBatch={12} windowSize={7} updateCellsBatchingPeriod={30} maintainVisibleContentPosition={{ minIndexForVisible: 1 }} ListHeaderComponent={hasOlder || loadingHistory ? <Pressable accessibilityRole="button" accessibilityLabel="Load older messages" disabled={loadingHistory} onPress={loadEarlier} style={{ alignItems: 'center', paddingVertical: 10 }}>{loadingHistory ? <ActivityIndicator size="small" color={muted} /> : <Text style={s.thinkingLabel}>Load older messages</Text>}</Pressable> : null} ListFooterComponent={transcriptFooter} onContentSizeChange={onTranscriptSize} onScroll={onTranscriptScroll} onScrollBeginDrag={onTranscriptDrag} scrollEventThrottle={100} keyboardShouldPersistTaps="handled" />{remote.status !== 'online' && <Pressable accessibilityRole="button" accessibilityLabel={remote.active ? 'Reconnect to host' : 'Connect to host'} onPress={() => remote.active ? remote.connect(remote.nearby.find(x => x.id === remote.active?.peer.id)?.address || remote.active.address, remote.active).catch(() => {}) : navigation.navigate('Settings')} style={[s.hostPill, { top: safeArea.top + 54 }]}>{remote.status === 'connecting' ? <ActivityIndicator size="small" color={ink} /> : <Glyph name="terminal" size={15} color={ink} />}<Text style={s.hostPillText}>{remote.status === 'connecting' ? 'Connecting to host' : remote.active ? 'Reconnect to host' : 'Connect to host'}</Text></Pressable>}{!atBottom && <Pressable accessibilityLabel="Jump to latest" style={[s.jump, { bottom: bottomPanelHeight + keyboardOffset + 12 }]} onPress={() => { following.current = true; userDragged.current = false; setAtBottom(true); scroll.current?.scrollToEnd({ animated: true }); }}><Glyph name="arrow.down" size={14} color={ink} /></Pressable>}</BlurTargetView></SwipeForward>
    <ProgressiveBlur edge="bottom" blurTarget={blurTarget} style={[s.bottomBlur, { bottom: keyboardOffset, height: bottomPanelHeight + 24 }]} />
    <View style={[s.bottomPanel, { bottom: keyboardOffset }]} onLayout={event => {
      const measuredHeight = event?.nativeEvent?.layout?.height;
      if (typeof measuredHeight !== 'number' || !Number.isFinite(measuredHeight)) return;
      setBottomPanelHeight(height => Math.abs(height - measuredHeight) < 1 ? height : measuredHeight);
    }}>
      <View style={s.contextRow}>
        <Pressable accessibilityRole="button" accessibilityLabel={`${worktreeKind.toLowerCase()} ${worktreeLabel}`} onPress={chat.projectId ? () => navigation.navigate('Worktrees', { projectId: chat.projectId }) : undefined} style={s.worktreeIndicator}>
          <Glyph name="branch" size={15} color={chat.worktreePath ? ink : tertiary} />
          <View style={s.worktreeText}><Text style={s.worktreeCaption}>{worktreeKind}</Text><Text style={s.worktreeName} numberOfLines={1} ellipsizeMode="middle">{worktreeLabel}</Text></View>
        </Pressable>
        {pr && <Pressable accessibilityRole="button" accessibilityLabel={`Pull request #${pr.number}`} onPress={() => navigation.navigate('PullRequest', { sessionId: id })} style={s.prContext}><PullRequestIcon pr={pr} size={14} /><Text style={s.prContextLabel}>#{pr.number}</Text></Pressable>}
        {diff.files > 0 && <Pressable accessibilityRole="button" accessibilityLabel={`Review ${diff.files} changed ${diff.files === 1 ? 'file' : 'files'}`} onPress={() => { Haptics.selectionAsync().catch(() => {}); navigation.navigate('Review', { sessionId: id }); }} style={s.changesPill}>
          <Glyph name="review" size={13} color={ink} /><Text style={s.changesPillLabel}>{diff.files} {diff.files === 1 ? 'file' : 'files'}</Text>{diff.added > 0 && <Text style={s.changesAdded}>+{diff.added}</Text>}{diff.removed > 0 && <Text style={s.changesRemoved}>−{diff.removed}</Text>}
        </Pressable>}
      </View>
    {menu === 'manage' && <View style={s.menu}><TextInput style={s.menuInput} value={rename} onChangeText={setRename} placeholder="Rename chat" placeholderTextColor={tertiary} /><Chip label="Rename" onPress={() => { if (rename.trim()) act('rename', { name: rename.trim() }); setMenu(null); }} /><Chip icon="close" onPress={() => setMenu(null)} label="Close" /></View>}
    <LinkPickerSheet kind={linkSheet} query={linkQuery} setQuery={setLinkQuery} results={linkResults} loading={linkLoading} search={() => linkSheet && searchLinks(linkSheet, linkQuery)} select={attachLink} close={() => setLinkSheet(null)} />
    <View style={[s.composerWrap, { paddingBottom: keyboardHeight ? 7 : safeArea.bottom + 7 }]}>
      {attachments.length > 0 && <ScrollView horizontal style={s.attachments} contentContainerStyle={{ gap: 5 }}>{attachments.map(item => <Chip key={item.id} label={`${item.reference ? `${item.reference} ` : ''}${item.title} ×`} onPress={() => setAttachments(attachments.filter(x => x.id !== item.id))} />)}</ScrollView>}
      <View style={s.composerBox}>
        <View style={s.composerTextRow}>
          {previewingMarkdown ? <ScrollView style={s.composerInput}><Markdown style={markdownStyles} rules={codeRules}>{message}</Markdown></ScrollView> : <TextInput value={message} onChangeText={value => { setMessage(value); setSlashChoosing(null); }} multiline style={s.composerInput} placeholder="Type / for commands" placeholderTextColor={tertiary} textAlignVertical="top" />}
        </View>
        <View style={s.composerActionRow}>
          <Pressable accessibilityLabel="Attach files" style={s.attachControl} onPress={() => pickAttachments(attachments).then(setAttachments).catch(e => Alert.alert('Attachment', String(e)))}><Glyph name="attach" size={18} color={muted} /></Pressable>
          <View style={s.composerTrailingActions}>
            {!!message && <Pressable accessibilityLabel={previewingMarkdown ? 'Edit Markdown' : 'Preview Markdown'} style={[s.composerAction, { width: previewingMarkdown ? 42 : 52 }]} onPress={() => setPreviewingMarkdown(!previewingMarkdown)}><Text style={s.previewLabel}>{previewingMarkdown ? 'Edit' : 'Preview'}</Text></Pressable>}
            {!!root && <Pressable accessibilityLabel="Link a GitHub issue" style={s.composerAction} onPress={() => openLinks('issue')}><IssueIcon size={18} /></Pressable>}
            {!!root && <Pressable accessibilityLabel="Link a pull request" style={s.composerAction} onPress={() => openLinks('linkPr')}><PullRequestIcon size={18} color={muted} /></Pressable>}
            <Pressable accessibilityLabel={chat.status === 'running' ? 'Stop agent' : 'Send message'} style={s.composerAction} onPress={() => chat.status === 'running' ? act('stop') : send()}><Glyph name={chat.status === 'running' ? 'stop' : 'send'} size={18} color={message.trim() || attachments.length || chat.status === 'running' ? ink : tertiary} /></Pressable>
          </View>
        </View>
      </View>
      <View style={s.controls}><NativeSelect label="Agent" value={chat.providerId === 'claude' ? 'Claude' : providerLabel} leading={<ProviderLogo provider={chat.providerId} size={13} />} choices={providerChoices} flex={1.15} onSelect={providerId => act('setAgent', { providerId, model: null, effort: null })} /><NativeSelect label="Model" value={modelLabel} choices={modelChoices} flex={1.35} onSelect={model => act('setAgent', { providerId: chat.providerId, model: model || null, effort: null })} /><NativeSelect label="Reasoning effort" value={effortLabel === 'Default effort' ? 'Default' : effortLabel} choices={effortChoices} flex={0.9} onSelect={effort => act('setAgent', { providerId: chat.providerId, model: chat.model, effort: effort || null })} /><NativeSelect label="Permissions" value={policyLabel === 'Ask before acting' ? 'Ask first' : policyLabel || 'Permissions'} choices={policyChoices} flex={1.35} onSelect={policy => act('setPolicy', { policy })} /></View>
      {slashPopupOpen && <SlashPopup key={slashChoosing || slashQuery || 'commands'} title={slashChoosing ? `/${slashChoosing}` : 'COMMANDS'} items={slashItems} maxHeight={slashPopupHeight} onBack={slashChoosing ? () => setSlashChoosing(null) : undefined} />}
    </View>
    </View>
  </SafeAreaView>;
}
const chrome = StyleSheet.create({
  toolbarButton: { width: 40, height: 44, alignItems: 'center', justifyContent: 'center' },
  nativeActions: { flexDirection: 'row', alignItems: 'center', gap: 0 },
});
const markdownStyles = StyleSheet.create({ body: { color: ink, fontFamily: 'Inter', fontSize: 15, lineHeight: 23 }, paragraph: { marginTop: 0, marginBottom: 10 }, heading1: { color: ink, fontFamily: 'Inter', fontSize: 19, fontWeight: '600', marginVertical: 8 }, heading2: { color: ink, fontFamily: 'Inter', fontSize: 16, fontWeight: '600', marginVertical: 8 }, heading3: { color: ink, fontFamily: 'Inter', fontSize: 14, fontWeight: '600', marginVertical: 6 }, code_inline: { color: ink, backgroundColor: '#303036', fontFamily: 'JetBrainsMono', fontSize: 12 }, code_block: { color: ink, backgroundColor: panel, fontFamily: 'JetBrainsMono', fontSize: 11, padding: 9, borderRadius: 6 }, fence: { color: ink, backgroundColor: panel, fontFamily: 'JetBrainsMono', fontSize: 11, padding: 9, borderRadius: 6 }, link: { color: '#91B8F6' }, bullet_list: { marginBottom: 10 }, ordered_list: { marginBottom: 10 }, blockquote: { backgroundColor: 'transparent', borderLeftColor: '#55555E', borderLeftWidth: 2, paddingLeft: 10 }, strong: { fontWeight: '700' } });
const s = StyleSheet.create({
  bottomBlur: { top: undefined, bottom: 0, zIndex: 1 },
  bottomPanel: { position: 'absolute', left: 0, right: 0, zIndex: 2 },
  contextRow: { height: 40, marginHorizontal: 10, flexDirection: 'row', alignItems: 'center', gap: 6 },
  worktreeIndicator: { flex: 1, minWidth: 0, height: 32, flexDirection: 'row', alignItems: 'center', gap: 7, paddingHorizontal: 8, borderRadius: 16, backgroundColor: raised, borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.16)' },
  worktreeText: { flex: 1, minWidth: 0, justifyContent: 'center' },
  worktreeCaption: { color: tertiary, fontFamily: 'Inter', fontSize: 9, fontWeight: '600', letterSpacing: 0.5, lineHeight: 11 },
  worktreeName: { color: ink, fontFamily: 'Inter', fontSize: 12, fontWeight: '600', lineHeight: 15 },
  changesPill: { minHeight: 32, flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 9, borderRadius: 16, backgroundColor: raised, borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.16)' },
  changesPillLabel: { color: ink, fontFamily: 'Inter', fontSize: 11, fontWeight: '600' },
  changesAdded: { color: '#4CC38A', fontFamily: 'JetBrainsMono', fontSize: 10 },
  changesRemoved: { color: '#EF6461', fontFamily: 'JetBrainsMono', fontSize: 10 },
  prContext: { minHeight: 32, flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 8, borderRadius: 16, backgroundColor: raised, borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.16)' },
  prContextLabel: { color: muted, fontFamily: 'Inter', fontSize: 11, fontWeight: '600' },
  composerBox: { borderRadius: 11, borderWidth: 1, borderColor: '#424249', backgroundColor: panel, paddingHorizontal: 8, paddingTop: 4, paddingBottom: 3 },
  composerTextRow: { minHeight: 44, flexDirection: 'row' },
  composerInput: { flex: 1, minHeight: 44, maxHeight: 160, color: ink, fontFamily: 'Inter', fontSize: 15, paddingHorizontal: 4, paddingTop: 9, paddingBottom: 4 },
  composerActionRow: { height: 38, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  composerTrailingActions: { flexDirection: 'row', alignItems: 'center' },
  composerAction: { width: 36, height: 38, alignItems: 'center', justifyContent: 'center' },
  attachControl: { width: 38, height: 38, alignItems: 'center', justifyContent: 'center' },
  root: { flex: 1, backgroundColor: canvas }, hostPill: { position: 'absolute', alignSelf: 'center', zIndex: 4, flexDirection: 'row', alignItems: 'center', gap: 9, paddingHorizontal: 14, minHeight: 38, borderRadius: 20, backgroundColor: raised, borderColor: border, borderWidth: 1 }, hostPillText: { color: ink, fontFamily: 'Inter', fontSize: 12.5, fontWeight: '600' }, sheetRoot: { flex: 1, backgroundColor: canvas }, sheetBackdrop: { flex: 1, justifyContent: 'flex-end', backgroundColor: 'rgba(0,0,0,0.55)' }, sheetPanel: { backgroundColor: canvas, minHeight: 390, maxHeight: '85%', borderTopLeftRadius: 18, borderTopRightRadius: 18, paddingHorizontal: 16 }, sheetHandle: { alignSelf: 'center', width: 36, height: 4, borderRadius: 2, backgroundColor: '#5C5C65', marginTop: 10, marginBottom: 12 }, sheetHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 15 }, sheetTitle: { color: ink, fontFamily: 'Inter', fontSize: 19, fontWeight: '600' }, sheetClose: { width: 38, height: 38, borderRadius: 19, backgroundColor: raised, alignItems: 'center', justifyContent: 'center' }, sheetSearch: { minHeight: 50, borderRadius: 10, backgroundColor: panel, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 12 }, sheetInput: { flex: 1, minWidth: 0, color: ink, fontFamily: 'Inter', fontSize: 15 }, sheetSearchButton: { minHeight: 38, justifyContent: 'center', paddingHorizontal: 6 }, sheetSearchButtonText: { color: ink, fontFamily: 'Inter', fontSize: 13, fontWeight: '600' }, sheetResults: { paddingTop: 12, paddingBottom: 25 }, sheetResult: { minHeight: 62, flexDirection: 'row', alignItems: 'center', gap: 12, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border }, sheetReference: { color: muted, fontFamily: 'JetBrainsMono', fontSize: 12 }, sheetResultTitle: { color: ink, fontFamily: 'Inter', fontSize: 14.5, lineHeight: 20 }, sheetResultMeta: { color: tertiary, fontFamily: 'Inter', fontSize: 11, marginTop: 2 }, sheetEmpty: { color: tertiary, fontFamily: 'Inter', fontSize: 13, textAlign: 'center', paddingTop: 28 }, waiting: { flex: 1, justifyContent: 'center', padding: 18, backgroundColor: canvas }, faint: { color: tertiary, fontFamily: 'Inter', fontSize: 10 }, chip: { flexDirection: 'row', alignItems: 'center', alignSelf: 'flex-start', gap: 5, paddingHorizontal: 9, paddingVertical: 7, borderRadius: 5 }, chipActive: { backgroundColor: '#303036' }, chipLabel: { color: muted, fontFamily: 'Inter', fontSize: 11.5, fontWeight: '500', maxWidth: 145 }, transcript: { flex: 1 }, transcriptContent: { paddingHorizontal: 16, paddingTop: 18, paddingBottom: 44, gap: 14 }, transcriptFooter: { gap: 12 }, userRow: { alignItems: 'flex-end' }, userBubble: { backgroundColor: raised, borderRadius: 11, paddingHorizontal: 13, paddingVertical: 10, maxWidth: '94%' }, prose: { color: ink, fontFamily: 'Inter', fontSize: 15, lineHeight: 23 }, thinkingRow: { gap: 4, paddingVertical: 2 }, thinkingLabel: { color: tertiary, fontFamily: 'Inter', fontSize: 12 }, thinkingText: { color: tertiary, fontFamily: 'Inter', fontSize: 13, lineHeight: 20, fontStyle: 'italic' }, turnRow: { flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 4 }, turnRule: { height: StyleSheet.hairlineWidth, backgroundColor: border, flex: 1 }, toolRow: { flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 38, paddingHorizontal: 2 }, toolIcon: { width: 20, height: 20, alignItems: 'center', justifyContent: 'center' }, toolVerb: { color: muted, fontFamily: 'Inter', fontWeight: '500', fontSize: 13.5 }, toolLabel: { flex: 1, color: tertiary, fontFamily: 'JetBrainsMono', fontSize: 12.5 }, toolFailed: { color: '#EF6461', fontFamily: 'Inter', fontSize: 10 }, toolPending: { color: tertiary, fontFamily: 'Inter', fontSize: 10 }, toolDetail: { color: tertiary, backgroundColor: panel, fontFamily: 'JetBrainsMono', fontSize: 11.5, lineHeight: 18, padding: 10, marginLeft: 22, borderRadius: 5 }, permission: { padding: 10, backgroundColor: raised, borderRadius: 8, gap: 7 }, permissionTitle: { color: ink, fontWeight: '600', fontSize: 12 }, permissionInput: { color: ink, padding: 7, backgroundColor: canvas, borderRadius: 5 }, permissionActions: { flexDirection: 'row' }, working: { flexDirection: 'row', alignItems: 'center', gap: 7 }, dotGrid: { width: 8, height: 13, flexDirection: 'row', flexWrap: 'wrap', columnGap: 2, rowGap: 2 }, dot: { width: 3, height: 3, borderRadius: 2, backgroundColor: muted }, workingLabel: { color: muted, fontFamily: 'Inter', fontSize: 13 }, workingDuration: { color: tertiary, fontFamily: 'Inter', fontSize: 13, fontVariant: ['tabular-nums'] }, jump: { position: 'absolute', right: 13, bottom: 12, width: 38, height: 38, borderRadius: 19, backgroundColor: raised, alignItems: 'center', justifyContent: 'center' }, slashMenu: { maxHeight: 220, backgroundColor: raised, borderTopColor: border, borderTopWidth: 1, padding: 5 }, slashRow: { flexDirection: 'row', alignItems: 'center', gap: 9, minHeight: 40, paddingHorizontal: 7 }, slashCommand: { color: ink, fontFamily: 'JetBrainsMono', fontSize: 11, minWidth: 55 }, slashDetail: { color: tertiary, fontFamily: 'Inter', fontSize: 10, flex: 1 }, menu: { maxHeight: 220, padding: 6, backgroundColor: raised, borderTopColor: border, borderTopWidth: 1 }, menuInput: { color: ink, fontSize: 14, padding: 9 }, linkSearch: { flexDirection: 'row', alignItems: 'center' }, linkResult: { flexDirection: 'row', alignItems: 'center', gap: 7, minHeight: 30, paddingHorizontal: 7 }, linkReference: { color: tertiary, fontFamily: 'JetBrainsMono', fontSize: 10 }, linkTitle: { color: ink, fontFamily: 'Inter', fontSize: 11, flex: 1 }, composerWrap: { paddingHorizontal: 10, paddingTop: 7, paddingBottom: 8 }, attachments: { maxHeight: 30 }, previewLabel: { color: muted, fontFamily: 'Inter', fontSize: 10 }, controls: { minHeight: 44, flexDirection: 'row', alignItems: 'center', width: '100%' } });
