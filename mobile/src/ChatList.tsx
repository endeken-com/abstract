import React, { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { MenuView } from '@react-native-menu/menu';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { ProviderLogo } from './ProviderLogo';
import { ProjectIcon } from './ProjectIcon';
import { PullRequestIcon } from './PullRequestIcon';
import { swiftDate } from './types';
import {
  activeAt, age, chatKey, defaultPrefs, filterIsEmpty, groupTitles, lineIsEmpty, lineOf, lineText,
  parsePrefs, sections, standalone, type ChatFacts, type ChatListPrefs, type ChatLine,
} from './chatGroups';

// Graphite values come from Abstract/Theme/Palette.swift.
const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E', sidebar = '#19191C', raised = '#2B2B30', inset = '#303036';
const removed = '#EF6461', running = '#4CC38A';
const prefsKey = 'chat-list';
const agentNames: Record<string, string> = { claude: 'Claude Code', codex: 'Codex', opencode: 'OpenCode' };

// The list's choices, kept across launches.
export function useChatListPrefs(): [ChatListPrefs, (next: ChatListPrefs) => void] {
  const [prefs, setPrefs] = useState(defaultPrefs);
  useEffect(() => { AsyncStorage.getItem(prefsKey).then(raw => setPrefs(parsePrefs(raw))).catch(() => {}); }, []);
  return [prefs, next => { setPrefs(next); AsyncStorage.setItem(prefsKey, JSON.stringify(next)).catch(() => {}); }];
}

// Re-renders every half minute, so "now" becomes "1m" on its own.
export function useTicking() {
  const [now, setNow] = useState(swiftDate());
  useEffect(() => { const timer = setInterval(() => setNow(swiftDate()), 30_000); return () => clearInterval(timer); }, []);
  return now;
}

// The rail's "Chats" header: a search button and the group-and-filter menu,
// with the search field under it while searching.
export function ChatListHeader({ all, prefs, setPrefs, searching, setSearching, query, setQuery }: {
  all: ChatFacts[]; prefs: ChatListPrefs; setPrefs: (next: ChatListPrefs) => void;
  searching: boolean; setSearching: (on: boolean) => void; query: string; setQuery: (text: string) => void;
}) {
  return <View>
    <View style={styles.header}>
      <Text style={styles.headerTitle}>Chats</Text>
      <Pressable accessibilityRole="button" accessibilityLabel="Search chats" onPress={() => { setSearching(!searching); if (searching) setQuery(''); }} style={styles.headerButton}>
        <SymbolView name={{ ios: 'magnifyingglass', android: 'search', web: 'search' } as any} size={17} tintColor={searching ? ink : muted} style={{ width: 17, height: 17 }} />
      </Pressable>
      <FilterMenu all={all} prefs={prefs} setPrefs={setPrefs} />
    </View>
    {searching && <View style={styles.search}>
      <TextInput autoFocus style={styles.searchInput} placeholder="Title, branch or PR number" placeholderTextColor={tertiary} value={query} onChangeText={setQuery} autoCapitalize="none" autoCorrect={false} clearButtonMode="while-editing" />
    </View>}
  </View>;
}

// Pinned, Needs you, Working, Ready to review, Done: across projects and Macs.
export function StatusGroups({ chats, now, showMac, isSelected, openChat }: {
  chats: ChatFacts[]; now: number; showMac: boolean;
  isSelected: (chat: ChatFacts) => boolean; openChat: (chat: ChatFacts) => void;
}) {
  const [showOlder, setShowOlder] = useState(false);
  const row = (chat: ChatFacts) => <ChatRow key={chatKey(chat)} chat={chat} showProject showMac={showMac} now={now} selected={isSelected(chat)} onPress={() => openChat(chat)} />;
  return <>{sections(chats, now).map(section => <View key={section.group} style={styles.group}>
    <Text style={styles.groupTitle}>{groupTitles[section.group]}</Text>
    {section.chats.map(row)}
    {showOlder && section.older.map(row)}
    {section.older.length > 0 && <Pressable accessibilityRole="button" onPress={() => setShowOlder(!showOlder)} style={styles.older}>
      <Text style={styles.olderText}>{showOlder ? 'Hide older' : `Show ${section.older.length} older`}</Text>
    </Pressable>}
  </View>)}</>;
}

export function NoMatches() { return <Text style={styles.empty}>No chats match</Text>; }

// The header's filter menu: how to group, which projects and agents, and archived chats.
function FilterMenu({ all, prefs, setPrefs }: { all: ChatFacts[]; prefs: ChatListPrefs; setPrefs: (next: ChatListPrefs) => void }) {
  const projects = [...new Set(all.map(c => c.projectName || standalone))].sort();
  const agents = [...new Set(all.map(c => c.session.providerId))].sort();
  const macs = [...new Set(all.map(c => c.mac))].sort();
  const on = (yes: boolean) => (yes ? 'on' : 'off') as 'on' | 'off';
  const toggle = (list: string[], value: string) => list.includes(value) ? list.filter(x => x !== value) : [...list, value];
  const filtered = !filterIsEmpty(prefs.filter);
  return <MenuView title="Chats" actions={[
    { id: 'arrangement', title: 'Group By', displayInline: true, subactions: [
      { id: 'arrangement:status', title: 'Status', state: on(prefs.arrangement === 'status') },
      { id: 'arrangement:project', title: 'Project', state: on(prefs.arrangement === 'project') },
    ] },
    { id: 'projects', title: 'Project', subactions: projects.map(name => ({ id: `project:${name}`, title: name, state: on(prefs.filter.projects.includes(name)) })) },
    { id: 'agents', title: 'Agent', subactions: agents.map(id => ({ id: `agent:${id}`, title: agentNames[id] || id, state: on(prefs.filter.agents.includes(id)) })) },
    ...(macs.length > 1 ? [{ id: 'macs', title: 'Mac', subactions: macs.map(name => ({ id: `mac:${name}`, title: name, state: on(prefs.filter.macs.includes(name)) })) }] : []),
    ...(filtered ? [{ id: 'clear', title: 'Show All Chats' }] : []),
    { id: 'archived', title: 'Show Archived Chats', state: on(prefs.showArchived) },
  ]} onPressAction={({ nativeEvent }) => {
    const id = nativeEvent.event, colon = id.indexOf(':');
    const [kind, value] = colon < 0 ? [id, ''] : [id.slice(0, colon), id.slice(colon + 1)];
    if (kind === 'arrangement') setPrefs({ ...prefs, arrangement: value === 'project' ? 'project' : 'status' });
    else if (kind === 'project') setPrefs({ ...prefs, filter: { ...prefs.filter, projects: toggle(prefs.filter.projects, value) } });
    else if (kind === 'agent') setPrefs({ ...prefs, filter: { ...prefs.filter, agents: toggle(prefs.filter.agents, value) } });
    else if (kind === 'mac') setPrefs({ ...prefs, filter: { ...prefs.filter, macs: toggle(prefs.filter.macs, value) } });
    else if (kind === 'clear') setPrefs({ ...prefs, filter: { projects: [], agents: [], macs: [] } });
    else if (kind === 'archived') setPrefs({ ...prefs, showArchived: !prefs.showArchived });
  }}>
    <View accessibilityRole="button" accessibilityLabel={filtered ? 'Group and filter chats, some are filtered out' : 'Group and filter chats'} style={styles.headerButton}>
      <SymbolView name={{ ios: filtered ? 'line.3.horizontal.decrease.circle.fill' : 'line.3.horizontal.decrease', android: 'filter_list', web: 'filter_list' } as any} size={17} tintColor={filtered ? ink : muted} style={{ width: 17, height: 17 }} />
    </View>
  </MenuView>;
}

// A chat: its project and state, title and age; a quiet second line with its
// project, pull request and Mac. Dimmed while archived, or while its Mac can't be reached.
export function ChatRow({ chat, showProject, showMac = false, now, selected, onPress }: {
  chat: ChatFacts; showProject: boolean; showMac?: boolean; now: number; selected?: boolean; onPress: () => void;
}) {
  const line = lineOf(chat, showProject, showMac);
  const dimmed = chat.session.archivedAt != null || chat.macState === 'unreachable';
  return <Pressable onPress={onPress} accessibilityRole="button" style={[styles.row, selected && styles.rowSelected, dimmed && { opacity: 0.5 }]}>
    <ChatMark chat={chat} working={chat.backgroundTasks} unreachable={chat.macState === 'unreachable'} />
    <View style={styles.rowText}>
      <View style={styles.firstLine}>
        <Text numberOfLines={1} style={styles.title}>{chat.session.name}</Text>
        <Text style={styles.age}>{age(activeAt(chat), now)}</Text>
      </View>
      {chat.macState === 'unreachable'
        ? <Text style={styles.age}>{chat.mac} isn't reachable{chat.lastSeenAt ? ` · last seen ${new Date(chat.lastSeenAt).toLocaleString()}` : ''}</Text>
        : !lineIsEmpty(line) && <SecondLine line={line} />}
    </View>
  </Pressable>;
}

// What leads a chat's row: its project's icon (its agent's logo when it has no
// project), with a small badge while it works, when it needs you, or when it failed.
function ChatMark({ chat, working, unreachable = false }: { chat: ChatFacts; working: boolean; unreachable?: boolean }) {
  const session = chat.session;
  const badge = unreachable ? tertiary : session.status === 'waiting_input' ? ink : session.status === 'errored' ? removed
    : session.status === 'running' || session.status === 'provisioning' || working ? running : null;
  return <View style={styles.mark} accessibilityLabel={`${chat.projectName || standalone}, ${agentNames[session.providerId] || session.providerId}, ${session.status.replace('_', ' ')}`}>
    {chat.icon.kind === 'project'
      ? <ProjectIcon mark={chat.icon.mark} size={20} />
      : <ProviderLogo provider={session.providerId} size={17} />}
    {badge && <View style={[styles.badge, { backgroundColor: badge }]} />}
  </View>;
}

export function SecondLine({ line }: { line: ChatLine }) {
  const mac = line.mac ? <View key="mac" style={styles.macPart}>
    <SymbolView name={{ ios: 'laptopcomputer', android: 'laptop_mac', web: 'laptop_mac' } as any} size={10} tintColor={tertiary} style={{ width: 12, height: 10 }} />
    <Text numberOfLines={1} style={[styles.part, styles.macName]}>{line.mac}</Text>
  </View> : null;
  const first: React.ReactNode[] = [];
  if (line.project) first.push(<Text key="project" numberOfLines={1} style={[styles.part, styles.projectName]}>{line.project}</Text>);
  if (line.pullRequest) first.push(<View key="pr" style={styles.prPart}><PullRequestIcon pr={line.pullRequest} size={11} /><Text numberOfLines={1} style={styles.part}>{`#${line.pullRequest.number}`}</Text></View>);
  if (line.checks) first.push(<Text key="checks" numberOfLines={1} style={[styles.part, line.checks === 'failing' && { color: removed }]}>{line.checks}</Text>);
  if (!line.changesRequested && mac) first.push(mac);
  const second: React.ReactNode[] = [];
  if (line.changesRequested) {
    second.push(<Text key="review" numberOfLines={1} style={[styles.part, styles.reviewStatus]}>changes requested</Text>);
    if (mac) second.push(mac);
  }
  const withDots = (parts: React.ReactNode[]) => parts.flatMap((part, i) => i ? [<Text key={`dot${i}`} style={styles.dot}>·</Text>, part] : [part]);
  return <View style={styles.secondLine} accessibilityLabel={lineText(line)}>
    <View style={styles.metadataRow}>{withDots(first)}</View>
    {second.length > 0 && <View style={styles.metadataRow}>{withDots(second)}</View>}
  </View>;
}

const styles = StyleSheet.create({
  header: { marginTop: 10, paddingLeft: 18, paddingRight: 10, height: 40, flexDirection: 'row', alignItems: 'center', gap: 2 },
  headerTitle: { color: tertiary, fontFamily: 'Inter', fontSize: 14, flex: 1 },
  headerButton: { width: 36, height: 36, alignItems: 'center', justifyContent: 'center' },
  search: { marginHorizontal: 14, marginBottom: 6, height: 38, borderRadius: 10, backgroundColor: inset, paddingHorizontal: 12, justifyContent: 'center' },
  searchInput: { color: ink, fontFamily: 'Inter', fontSize: 14.5, padding: 0 },
  group: { paddingTop: 10 },
  groupHeader: { paddingHorizontal: 18, height: 36, flexDirection: 'row', alignItems: 'center', gap: 6 },
  groupTitle: { color: muted, fontFamily: 'Inter', fontSize: 13.5, fontWeight: '600', paddingHorizontal: 18, paddingVertical: 8 },
  row: { minHeight: 44, paddingVertical: 7, paddingLeft: 22, paddingRight: 18, flexDirection: 'row', alignItems: 'flex-start', gap: 10 },
  rowSelected: { backgroundColor: raised },
  rowText: { flex: 1, minWidth: 0, gap: 2 },
  firstLine: { flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 20 },
  title: { color: ink, fontFamily: 'Inter', fontSize: 14.5, flex: 1 },
  age: { color: tertiary, fontFamily: 'Inter', fontSize: 12, fontVariant: ['tabular-nums'] },
  mark: { width: 20, height: 20, alignItems: 'center', justifyContent: 'center' },
  badge: { position: 'absolute', right: -1, bottom: -1, width: 7, height: 7, borderWidth: 1.5, borderColor: sidebar, transform: [{ rotate: '45deg' }] },
  secondLine: { minWidth: 0, gap: 1 },
  metadataRow: { flexDirection: 'row', alignItems: 'center', gap: 5, minWidth: 0 },
  prPart: { flexDirection: 'row', alignItems: 'center', gap: 3, flexShrink: 0 },
  macPart: { flexDirection: 'row', alignItems: 'center', gap: 3, flexShrink: 1, minWidth: 12 },
  part: { color: tertiary, fontFamily: 'Inter', fontSize: 12 },
  projectName: { flexShrink: 1, minWidth: 0 },
  macName: { flexShrink: 1, minWidth: 0 },
  reviewStatus: { color: muted, flexShrink: 0, maxWidth: '85%' },
  dot: { color: tertiary, fontFamily: 'Inter', fontSize: 12, opacity: 0.7, flexShrink: 0 },
  older: { height: 36, paddingLeft: 52, justifyContent: 'center' },
  olderText: { color: tertiary, fontFamily: 'Inter', fontSize: 13 },
  empty: { color: muted, fontFamily: 'Inter', fontSize: 12, margin: 18 },
});
