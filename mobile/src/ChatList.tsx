import React, { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { MenuView } from '@react-native-menu/menu';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { ProviderLogo } from './ProviderLogo';
import { PullRequestIcon } from './PullRequestIcon';
import { swiftDate, type Session, type Snapshot } from './types';
import {
  activeAt, age, chatsFromSnapshot, defaultPrefs, filterIsEmpty, filterMatches, groupTitles, lineIsEmpty, lineOf, lineText,
  parsePrefs, queryMatches, sections, standalone, type ChatFacts, type ChatListPrefs, type ChatLine,
} from './chatGroups';

// Graphite values come from Abstract/Theme/Palette.swift.
const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E', sidebar = '#19191C', raised = '#2B2B30', inset = '#303036';
const removed = '#EF6461', running = '#4CC38A';
const prefsKey = 'chat-list';
const agentNames: Record<string, string> = { claude: 'Claude Code', codex: 'Codex', opencode: 'OpenCode' };

// The list's choices, kept across launches.
function usePrefs(): [ChatListPrefs, (next: ChatListPrefs) => void] {
  const [prefs, setPrefs] = useState(defaultPrefs);
  useEffect(() => { AsyncStorage.getItem(prefsKey).then(raw => setPrefs(parsePrefs(raw))).catch(() => {}); }, []);
  return [prefs, next => { setPrefs(next); AsyncStorage.setItem(prefsKey, JSON.stringify(next)).catch(() => {}); }];
}

// Re-renders every half minute, so "now" becomes "1m" on its own.
function useTicking() {
  const [now, setNow] = useState(swiftDate());
  useEffect(() => { const timer = setInterval(() => setNow(swiftDate()), 30_000); return () => clearInterval(timer); }, []);
  return now;
}

// The rail's chats: grouped by what they need from you, or under their projects.
export function ChatList({ snapshot, selectedChat, openChat, openProject }: {
  snapshot: Snapshot | null | undefined; selectedChat?: string | null;
  openChat: (sessionId: string) => void; openProject: (projectId: string) => void;
}) {
  const [prefs, setPrefs] = usePrefs();
  const [searching, setSearching] = useState(false);
  const [query, setQuery] = useState('');
  const [showOlder, setShowOlder] = useState(false);
  const now = useTicking();
  if (!snapshot) return null;
  const all = chatsFromSnapshot(snapshot);
  const visible = all.filter(c => (prefs.showArchived || c.session.archivedAt == null) && filterMatches(prefs.filter, c) && queryMatches(c, query));
  const narrowing = !filterIsEmpty(prefs.filter) || !!query.trim();
  const row = (chat: ChatFacts, showProject: boolean) =>
    <ChatRow key={chat.session.id} chat={chat} showProject={showProject} now={now} selected={selectedChat === chat.session.id} onPress={() => openChat(chat.session.id)} />;

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
    {prefs.arrangement === 'status'
      ? sections(visible, now).map(section => <View key={section.group} style={styles.group}>
        <Text style={styles.groupTitle}>{groupTitles[section.group]}</Text>
        {section.chats.map(chat => row(chat, true))}
        {showOlder && section.older.map(chat => row(chat, true))}
        {section.older.length > 0 && <Pressable accessibilityRole="button" onPress={() => setShowOlder(!showOlder)} style={styles.older}>
          <Text style={styles.olderText}>{showOlder ? 'Hide older' : `Show ${section.older.length} older`}</Text>
        </Pressable>}
      </View>)
      : <>
        {snapshot.projects.map(project => {
          const chats = visible.filter(c => c.session.projectId === project.id).sort((a, b) => b.session.createdAt - a.session.createdAt);
          if (narrowing && !chats.length) return null;
          return <View key={project.id} style={styles.group}>
            <Pressable onPress={() => openProject(project.id)} style={styles.groupHeader}>
              <Text numberOfLines={1} style={[styles.groupTitle, { flex: 1, paddingHorizontal: 0 }]}>{project.name}</Text>
              <SymbolView name={{ ios: 'chevron.right', android: 'chevron_right', web: 'chevron_right' } as any} size={12} tintColor={tertiary} style={{ width: 12, height: 12 }} />
            </Pressable>
            {chats.map(chat => row(chat, false))}
          </View>;
        })}
        {visible.some(c => !c.session.projectId) && <View style={styles.group}>
          <Text style={styles.groupTitle}>{standalone}</Text>
          {visible.filter(c => !c.session.projectId).sort((a, b) => b.session.createdAt - a.session.createdAt).map(chat => row(chat, false))}
        </View>}
      </>}
    {narrowing && !visible.length && <Text style={styles.empty}>No chats match</Text>}
  </View>;
}

// The header's filter menu: how to group, which projects and agents, and archived chats.
function FilterMenu({ all, prefs, setPrefs }: { all: ChatFacts[]; prefs: ChatListPrefs; setPrefs: (next: ChatListPrefs) => void }) {
  const projects = [...new Set(all.map(c => c.projectName || standalone))].sort();
  const agents = [...new Set(all.map(c => c.session.providerId))].sort();
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
    ...(filtered ? [{ id: 'clear', title: 'Show All Chats' }] : []),
    { id: 'archived', title: 'Show Archived Chats', state: on(prefs.showArchived) },
  ]} onPressAction={({ nativeEvent }) => {
    const id = nativeEvent.event, colon = id.indexOf(':');
    const [kind, value] = colon < 0 ? [id, ''] : [id.slice(0, colon), id.slice(colon + 1)];
    if (kind === 'arrangement') setPrefs({ ...prefs, arrangement: value === 'project' ? 'project' : 'status' });
    else if (kind === 'project') setPrefs({ ...prefs, filter: { ...prefs.filter, projects: toggle(prefs.filter.projects, value) } });
    else if (kind === 'agent') setPrefs({ ...prefs, filter: { ...prefs.filter, agents: toggle(prefs.filter.agents, value) } });
    else if (kind === 'clear') setPrefs({ ...prefs, filter: { projects: [], agents: [] } });
    else if (kind === 'archived') setPrefs({ ...prefs, showArchived: !prefs.showArchived });
  }}>
    <View accessibilityRole="button" accessibilityLabel={filtered ? 'Group and filter chats, some are filtered out' : 'Group and filter chats'} style={styles.headerButton}>
      <SymbolView name={{ ios: filtered ? 'line.3.horizontal.decrease.circle.fill' : 'line.3.horizontal.decrease', android: 'filter_list', web: 'filter_list' } as any} size={17} tintColor={filtered ? ink : muted} style={{ width: 17, height: 17 }} />
    </View>
  </MenuView>;
}

// A chat: its agent and state, title and age; a quiet second line with its project and pull request.
export function ChatRow({ chat, showProject, now, selected, onPress }: { chat: ChatFacts; showProject: boolean; now: number; selected?: boolean; onPress: () => void }) {
  const line = lineOf(chat, showProject);
  return <Pressable onPress={onPress} accessibilityRole="button" style={[styles.row, selected && styles.rowSelected, chat.session.archivedAt != null && { opacity: 0.5 }]}>
    <AgentMark session={chat.session} working={chat.backgroundTasks} />
    <View style={styles.rowText}>
      <View style={styles.firstLine}>
        <Text numberOfLines={1} style={styles.title}>{chat.session.name}</Text>
        <Text style={styles.age}>{age(activeAt(chat), now)}</Text>
      </View>
      {!lineIsEmpty(line) && <SecondLine line={line} />}
    </View>
  </Pressable>;
}

// The agent's logo, with a small badge while it works, when it needs you, or when it failed.
function AgentMark({ session, working }: { session: Session; working: boolean }) {
  const badge = session.status === 'waiting_input' ? ink : session.status === 'errored' ? removed
    : session.status === 'running' || session.status === 'provisioning' || working ? running : null;
  return <View style={styles.mark} accessibilityLabel={`${agentNames[session.providerId] || session.providerId}, ${session.status.replace('_', ' ')}`}>
    <ProviderLogo provider={session.providerId} size={17} />
    {badge && <View style={[styles.badge, { backgroundColor: badge }]} />}
  </View>;
}

export function SecondLine({ line }: { line: ChatLine }) {
  const parts: React.ReactNode[] = [];
  if (line.project) parts.push(<Text key="project" numberOfLines={1} style={styles.part}>{line.project}</Text>);
  if (line.pullRequest) parts.push(<View key="pr" style={styles.prPart}><PullRequestIcon pr={line.pullRequest} size={11} /><Text style={styles.part}>{`#${line.pullRequest.number}`}</Text></View>);
  if (line.checks) parts.push(<Text key="checks" style={[styles.part, line.checks === 'failing' && { color: removed }]}>{line.checks}</Text>);
  if (line.changesRequested) parts.push(<Text key="review" style={[styles.part, { color: muted }]}>changes requested</Text>);
  return <View style={styles.secondLine} accessibilityLabel={lineText(line)}>
    {parts.flatMap((part, i) => i ? [<Text key={`dot${i}`} style={styles.dot}>·</Text>, part] : [part])}
  </View>;
}

const styles = StyleSheet.create({
  header: { marginTop: 18, paddingLeft: 18, paddingRight: 10, height: 40, flexDirection: 'row', alignItems: 'center', gap: 2 },
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
  secondLine: { flexDirection: 'row', alignItems: 'center', gap: 5, minWidth: 0 },
  prPart: { flexDirection: 'row', alignItems: 'center', gap: 3 },
  part: { color: tertiary, fontFamily: 'Inter', fontSize: 12, flexShrink: 1 },
  dot: { color: tertiary, fontFamily: 'Inter', fontSize: 12, opacity: 0.7 },
  older: { height: 36, paddingLeft: 52, justifyContent: 'center' },
  olderText: { color: tertiary, fontFamily: 'Inter', fontSize: 13 },
  empty: { color: muted, fontFamily: 'Inter', fontSize: 12, margin: 18 },
});
