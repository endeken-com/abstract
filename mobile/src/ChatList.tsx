import React, { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, Animated, LayoutAnimation, Platform, Pressable, StyleSheet, Text, TextInput, useWindowDimensions, View } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { CompactMenu as MenuView } from './CompactMenu';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { ProviderLogo } from './ProviderLogo';
import { ProjectIcon } from './ProjectIcon';
import { PullRequestIcon } from './PullRequestIcon';
import { swiftDate } from './types';
import {
  activeAt, age, agentNames, badgeOf, chatKey, defaultPrefs, filterIsEmpty, groupTitles, lineIsEmpty, lineOf, lineText,
  parsePrefs, rowLabel, sections, standalone, statusOf, type ChatFacts, type ChatGroup, type ChatListPrefs, type ChatLine,
} from './chatGroups';

// Graphite values come from Abstract/Theme/Palette.swift.
const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E', sidebar = '#19191C', raised = '#2B2B30', inset = '#303036';
const removed = '#EF6461', running = '#4CC38A', warning = '#D2D2D8', pressedRipple = 'rgba(236,236,239,0.08)';
const markSize = 22;
// A check's state as a symbol beside its word, as the Mac's sidebar shows it.
const checkSymbols = {
  passed: { ios: 'checkmark', android: 'check', web: 'check' },
  failing: { ios: 'xmark', android: 'close', web: 'close' },
  running: { ios: 'clock', android: 'schedule', web: 'schedule' },
};
const checkColors = { passed: running, failing: removed, running: muted };
const prefsKey = 'chat-list';
// The groups that ask something of you lead in full ink; the rest stay quiet.
const loudGroups: ChatGroup[] = ['needsYou', 'readyToReview'];
// From the largest standard text size up, metadata stacks instead of squeezing, as iOS lists do.
const stackedScale = 1.35;

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

// Follows the system's Reduce Motion setting.
function useReduceMotion() {
  const [reduce, setReduce] = useState(false);
  useEffect(() => {
    AccessibilityInfo.isReduceMotionEnabled().then(setReduce).catch(() => {});
    const sub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduce);
    return () => sub.remove();
  }, []);
  return reduce;
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
      <TextInput autoFocus accessibilityLabel="Search chats" style={styles.searchInput} placeholder="Title, branch or PR number" placeholderTextColor={tertiary} value={query} onChangeText={setQuery} autoCapitalize="none" autoCorrect={false} clearButtonMode="while-editing" returnKeyType="search" />
    </View>}
  </View>;
}

// Pinned, Needs you, Working, Ready to review, Done: across projects and Macs.
export function StatusGroups({ chats, now, showMac, isSelected, openChat }: {
  chats: ChatFacts[]; now: number; showMac: boolean;
  isSelected: (chat: ChatFacts) => boolean; openChat: (chat: ChatFacts) => void;
}) {
  const [showOlder, setShowOlder] = useState(false);
  const reduceMotion = useReduceMotion();
  const toggleOlder = () => {
    if (!reduceMotion) LayoutAnimation.configureNext(LayoutAnimation.create(180, 'easeInEaseOut', 'opacity'));
    setShowOlder(!showOlder);
  };
  return <>{sections(chats, now).map(section => {
    const row = (chat: ChatFacts) => <ChatRow key={chatKey(chat)} chat={chat} group={section.group} showProject showMac={showMac} now={now} selected={isSelected(chat)} onPress={() => openChat(chat)} />;
    const count = section.chats.length + section.older.length;
    return <View key={section.group} style={styles.group}>
      <View accessible accessibilityRole="header" accessibilityLabel={`${groupTitles[section.group]}, ${count} ${count === 1 ? 'chat' : 'chats'}`} style={styles.groupHeader}>
        <Text numberOfLines={1} style={[styles.groupTitle, loudGroups.includes(section.group) && styles.groupTitleLoud]}>{groupTitles[section.group]}</Text>
        <Text style={styles.groupCount}>{count}</Text>
      </View>
      {section.chats.map(row)}
      {showOlder && section.older.map(row)}
      {section.older.length > 0 && <Pressable accessibilityRole="button" accessibilityState={{ expanded: showOlder }} onPress={toggleOlder}
        android_ripple={{ color: pressedRipple }} style={({ pressed }) => [styles.older, pressed && Platform.OS === 'ios' && { opacity: 0.6 }]}>
        <Text style={styles.olderText}>{showOlder ? 'Hide older' : `Show ${section.older.length} older`}</Text>
        <SymbolView name={{ ios: showOlder ? 'chevron.up' : 'chevron.down', android: showOlder ? 'expand_less' : 'expand_more', web: 'expand_more' } as any} size={11} tintColor={tertiary} style={{ width: 12, height: 11 }} />
      </Pressable>}
    </View>;
  })}</>;
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

// A chat: its project's icon and state, title and age; under them, who it is
// on the left (why it needs you, project, Mac) and its pull request on the right,
// where the eye finds it in the same column on every row. Dimmed while archived,
// or while its Mac can't be reached.
export function ChatRow({ chat, group, showProject, showMac = false, now, selected, onPress }: {
  chat: ChatFacts; group?: ChatGroup; showProject: boolean; showMac?: boolean; now: number; selected?: boolean; onPress: () => void;
}) {
  const line = lineOf(chat, showProject, showMac, now, group);
  const unreachable = chat.macState === 'unreachable';
  const dimmed = chat.session.archivedAt != null || unreachable;
  const quiet = !selected && !unreachable && chat.session.pinnedAt == null && statusOf(chat) === 'done';
  const { fontScale } = useWindowDimensions();
  const stacked = fontScale >= stackedScale;
  return <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={rowLabel(chat, line, now)} accessibilityHint="Opens the chat"
    accessibilityState={{ selected: !!selected }} android_ripple={{ color: pressedRipple }}
    style={({ pressed }) => [styles.row, selected && styles.rowSelected, pressed && Platform.OS === 'ios' && styles.rowPressed]}>
    <View style={[styles.rowContent, dimmed && { opacity: 0.5 }]}>
      <ChatMark chat={chat} />
      <View style={styles.rowText}>
        <View style={styles.firstLine}>
          <Text numberOfLines={1} style={[styles.title, quiet && styles.titleQuiet]}>{chat.session.name}</Text>
          <Text numberOfLines={1} style={styles.age}>{age(activeAt(chat), now)}</Text>
        </View>
        {unreachable
          ? <Text numberOfLines={1} style={styles.part}>{chat.mac} isn't reachable{chat.lastSeenAt ? ` · last seen ${lastSeen(chat.lastSeenAt, now)}` : ''}</Text>
          : !lineIsEmpty(line) && <SecondLine line={line} stacked={stacked} symbolScale={Math.min(Math.max(fontScale, 1), 2)} />}
      </View>
    </View>
  </Pressable>;
}

// When an unreachable Mac was last heard from (a JavaScript date), as briefly as the row's age.
const lastSeen = (at: number, now: number) => { const text = age(at / 1000 - 978_307_200, now); return text === 'now' ? 'just now' : `${text} ago`; };

// What leads a chat's row: its project's icon (its agent's logo when it has no
// project), with a badge for its state, as the Mac's sidebar draws it: an
// outline while it works (breathing, unless Reduce Motion is on), filled when
// it needs you, red when it failed. At rest, just the icon. The row's label says it in words.
function ChatMark({ chat }: { chat: ChatFacts }) {
  const badge = badgeOf(chat);
  const color = badge === 'unreachable' ? tertiary : badge === 'stalled' ? warning : badge === 'needsYou' ? ink : badge === 'failed' ? removed : running;
  return <View style={styles.mark}>
    {chat.icon.kind === 'project'
      ? <ProjectIcon mark={chat.icon.mark} size={markSize} />
      : <ProviderLogo provider={chat.session.providerId} size={19} />}
    {badge && <View style={styles.badgeHole}>
      {badge === 'working' ? <WorkingBadge /> : <View style={[styles.badge, { backgroundColor: color }]} />}
    </View>}
  </View>;
}

function WorkingBadge() {
  const reduceMotion = useReduceMotion();
  const pulse = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    if (reduceMotion) { pulse.setValue(1); return; }
    const loop = Animated.loop(Animated.sequence([
      Animated.timing(pulse, { toValue: 0.35, duration: 900, useNativeDriver: true }),
      Animated.timing(pulse, { toValue: 1, duration: 900, useNativeDriver: true }),
    ]));
    loop.start();
    return () => loop.stop();
  }, [reduceMotion]);
  return <Animated.View style={[styles.badge, styles.badgeOutline, { opacity: pulse }]} />;
}

// The metadata under a title. Identity (why it needs you, project, Mac) leads on
// the left and gives way first; the pull request, its checks and review keep
// their full words on the right. At accessibility text sizes each takes its own
// line, and the symbols grow with the text.
export function SecondLine({ line, stacked = false, symbolScale = 1 }: { line: ChatLine; stacked?: boolean; symbolScale?: number }) {
  const z = (size: number) => Math.round(size * symbolScale);
  const identity: React.ReactNode[] = [];
  if (line.attention) identity.push(<Text key="attention" numberOfLines={1} style={[styles.part, styles.attention, line.attention === 'Failed' && { color: removed }]}>{line.attention}</Text>);
  if (line.stall) identity.push(<Text key="stall" numberOfLines={1} style={[styles.part, { color: warning, flexShrink: 0 }]}>{line.stall}</Text>);
  if (line.project) identity.push(<Text key="project" numberOfLines={1} style={[styles.part, styles.projectName]}>{line.project}</Text>);
  if (line.mac) identity.push(<View key="mac" style={styles.macPart}>
    <SymbolView name={{ ios: 'laptopcomputer', android: 'laptop_mac', web: 'laptop_mac' } as any} size={z(10)} tintColor={tertiary} style={{ width: z(13), height: z(10) }} />
    <Text numberOfLines={1} style={[styles.part, styles.macName]}>{line.mac}</Text>
  </View>);
  const pr = line.pullRequest && <View key="pr" style={styles.prPart}>
    <PullRequestIcon pr={line.pullRequest} size={z(11)} />
    <Text numberOfLines={1} style={[styles.part, styles.prNumber]}>{`#${line.pullRequest.number}`}</Text>
    {line.checks && <View style={styles.checks}>
      <SymbolView name={checkSymbols[line.checks] as any} size={z(9)} weight="semibold" tintColor={checkColors[line.checks]} style={{ width: z(10), height: z(10) }} />
      <Text numberOfLines={1} style={[styles.part, styles.checkWord, { color: checkColors[line.checks] }]}>{line.checks}</Text>
    </View>}
  </View>;
  const review = line.changesRequested && <View key="review" style={styles.reviewPart}>
    <SymbolView name={{ ios: 'text.bubble', android: 'rate_review', web: 'rate_review' } as any} size={z(10)} tintColor={muted} style={{ width: z(12), height: z(10) }} />
    <Text numberOfLines={1} style={[styles.part, styles.reviewStatus]}>changes requested</Text>
  </View>;
  const withDots = (parts: React.ReactNode[]) => parts.flatMap((part, i) => i ? [<Text key={`dot${i}`} style={styles.dot}>·</Text>, part] : [part]);
  const left = identity.length > 0 && <View key="identity" style={styles.identity}>{withDots(identity)}</View>;
  const rows = stacked
    ? [left, pr && <View key="pr" style={styles.metadataRow}>{pr}</View>, review && <View key="review" style={styles.metadataRow}>{review}</View>]
    : [<View key="main" style={styles.metadataRow}>{left}{pr && <View style={styles.trailing}>{pr}</View>}</View>,
      review && <View key="review" style={[styles.metadataRow, styles.trailingRow]}>{review}</View>];
  return <View style={styles.secondLine} accessibilityLabel={lineText(line)}>{rows.filter(Boolean)}</View>;
}

const styles = StyleSheet.create({
  header: { marginTop: 10, paddingLeft: 18, paddingRight: 6, minHeight: 44, flexDirection: 'row', alignItems: 'center' },
  headerTitle: { color: tertiary, fontFamily: 'Inter', fontSize: 14, flex: 1 },
  headerButton: { width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
  search: { marginHorizontal: 14, marginBottom: 6, minHeight: 38, borderRadius: 10, backgroundColor: inset, paddingHorizontal: 12, paddingVertical: 8, justifyContent: 'center' },
  searchInput: { color: ink, fontFamily: 'Inter', fontSize: 14.5, padding: 0 },
  group: { paddingTop: 14 },
  groupHeader: { paddingHorizontal: 18, minHeight: 30, paddingBottom: 2, flexDirection: 'row', alignItems: 'center', gap: 8 },
  groupTitle: { color: tertiary, fontFamily: 'Inter', fontSize: 13, fontWeight: '600', flexShrink: 1 },
  groupTitleLoud: { color: ink },
  groupCount: { color: tertiary, fontFamily: 'Inter', fontSize: 12, fontVariant: ['tabular-nums'] },
  row: { marginHorizontal: 8, borderRadius: 10, overflow: 'hidden' },
  rowContent: { minHeight: 48, paddingVertical: 8, paddingLeft: 14, paddingRight: 10, flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  rowSelected: { backgroundColor: raised },
  rowPressed: { backgroundColor: inset },
  rowText: { flex: 1, minWidth: 0, gap: 3 },
  firstLine: { flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: markSize },
  title: { color: ink, fontFamily: 'Inter', fontSize: 15, flex: 1 },
  titleQuiet: { color: muted },
  age: { color: tertiary, fontFamily: 'Inter', fontSize: 12, fontVariant: ['tabular-nums'], flexShrink: 0 },
  mark: { width: markSize, height: markSize, alignItems: 'center', justifyContent: 'center' },
  badgeHole: { position: 'absolute', right: -4, bottom: -4, width: 12, height: 12, alignItems: 'center', justifyContent: 'center', backgroundColor: sidebar, borderRadius: 3, transform: [{ rotate: '45deg' }] },
  badge: { width: 7, height: 7, borderRadius: 1.5 },
  badgeOutline: { borderWidth: 1.5, borderColor: running },
  secondLine: { minWidth: 0, gap: 2 },
  metadataRow: { flexDirection: 'row', alignItems: 'center', gap: 5, minWidth: 0 },
  identity: { flexDirection: 'row', alignItems: 'center', gap: 5, flexShrink: 1, minWidth: 0, overflow: 'hidden' },
  trailing: { marginLeft: 'auto', paddingLeft: 8, flexShrink: 0 },
  trailingRow: { justifyContent: 'flex-end' },
  // Only the largest text on the narrowest phone ever cuts these; beside identity the column keeps its width.
  prPart: { flexDirection: 'row', alignItems: 'center', gap: 3, flexShrink: 1, minWidth: 0 },
  prNumber: { fontVariant: ['tabular-nums'] },
  checks: { flexDirection: 'row', alignItems: 'center', gap: 2, marginLeft: 4, flexShrink: 1, minWidth: 0 },
  checkWord: { flexShrink: 1 },
  macPart: { flexDirection: 'row', alignItems: 'center', gap: 2, flexShrink: 1, minWidth: 13 },
  part: { color: tertiary, fontFamily: 'Inter', fontSize: 12.5 },
  attention: { color: ink, fontWeight: '600', flexShrink: 0 },
  projectName: { flexShrink: 1, minWidth: 0 },
  macName: { flexShrink: 1, minWidth: 0 },
  reviewPart: { flexDirection: 'row', alignItems: 'center', gap: 3, flexShrink: 1, minWidth: 0 },
  reviewStatus: { color: muted, flexShrink: 1 },
  dot: { color: tertiary, fontFamily: 'Inter', fontSize: 12.5, opacity: 0.7, flexShrink: 0 },
  older: { minHeight: 44, marginHorizontal: 8, paddingLeft: 48, flexDirection: 'row', alignItems: 'center', gap: 5 },
  olderText: { color: tertiary, fontFamily: 'Inter', fontSize: 13 },
  empty: { color: muted, fontFamily: 'Inter', fontSize: 12, margin: 18 },
});
