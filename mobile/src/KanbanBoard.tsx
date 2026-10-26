import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, TextInput, useWindowDimensions, View } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { CompactMenu as MenuView } from './CompactMenu';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { useHeaderHeight } from '@react-navigation/elements';
import { remote } from './remote';
import { chatsFromMacs } from './chatGroups';
import { useTicking } from './ChatList';
import { ProviderLogo } from './ProviderLogo';
import { buildBoard, emptyFilter, isFilterActive, normalizeFilter, pruneFilter, type BoardCard, type BoardFilter } from './kanban';

// Graphite values come from Abstract/Theme/Palette.swift.
const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E', panel = '#252529', raised = '#2B2B30', inset = '#303036';
const border = 'rgba(255,255,255,0.075)';
const prefsKey = 'kanban-board';

function useBoardFilter(): [BoardFilter, (next: BoardFilter) => void] {
  const [filter, setFilter] = useState<BoardFilter>(emptyFilter());
  useEffect(() => {
    AsyncStorage.getItem(prefsKey).then(raw => { try { setFilter(normalizeFilter(JSON.parse(raw || 'null'))); } catch { setFilter(emptyFilter()); } }).catch(() => {});
  }, []);
  return [filter, next => { setFilter(next); AsyncStorage.setItem(prefsKey, JSON.stringify(next)).catch(() => {}); }];
}

// Chats as a board, by what they need from you — the Mac Kanban plugin's
// board, from the paired Macs' snapshots. Tapping a card opens that chat.
export function KanbanBoardScreen({ navigation }: any) {
  const [, rerender] = useState(0);
  useEffect(() => remote.subscribe(() => rerender(x => x + 1)), []);
  const headerHeight = useHeaderHeight();
  const { width } = useWindowDimensions();
  const now = useTicking();
  const [filter, setFilter] = useBoardFilter();
  const macs = remote.macs();
  const chats = useMemo(() => chatsFromMacs(macs), [macs]);
  const built = useMemo(() => buildBoard(macs, chats, filter, now), [macs, chats, filter, now]);

  // Choices for projects/agents/Macs that no longer exist would hide chats
  // for no visible reason; drop them once, as the Mac board does.
  const prunedFor = useRef('');
  useEffect(() => {
    const key = JSON.stringify([filter.projects, filter.agents, filter.macs, built.projects.map(p => p.key), built.agents.map(a => a.key), built.macs.map(m => m.key)]);
    if (prunedFor.current === key) return;
    prunedFor.current = key;
    const next = pruneFilter(filter, built);
    if (JSON.stringify(next) !== JSON.stringify(filter)) setFilter(next);
  }, [filter, built, setFilter]);

  const columnWidth = Math.min(width - 32, 340);
  const openChat = (card: BoardCard) => navigation.navigate('Chat', { hostId: card.chat.hostId, sessionId: card.id });

  return <View style={[styles.screen, { paddingTop: headerHeight }]}>
    <View style={styles.toolbar}>
      <View style={styles.search}>
        <TextInput style={styles.searchInput} placeholder="Title, branch or PR number" placeholderTextColor={tertiary}
          value={filter.search} onChangeText={search => setFilter({ ...filter, search })} autoCapitalize="none" autoCorrect={false} clearButtonMode="while-editing" />
      </View>
      <BoardFilterMenu filter={filter} setFilter={setFilter} projects={built.projects} agents={built.agents} macs={built.macs} />
    </View>
    <Text style={styles.summary}>{built.shown === built.total
      ? `${built.total} ${built.total === 1 ? 'chat' : 'chats'}, by what they need from you.`
      : `Showing ${built.shown} of ${built.total} chats.`}</Text>
    {built.unreachableMacs.length > 0 && <Text style={styles.unreachable}>{built.unreachableMacs.join(', ')}{built.unreachableMacs.length === 1 ? " isn't reachable" : " aren't reachable"}, so its chats may be out of date.</Text>}
    {built.emptyKind === 'noChats'
      ? <Text style={styles.empty}>{macs.length ? 'No chats yet. Start a chat and it will appear here.' : 'Pair a Mac to see its chats.'}</Text>
      : built.emptyKind === 'noMatches'
        ? <View>
          <Text style={styles.empty}>No chats match these filters. Clear the filters to see them all.</Text>
          {isFilterActive(filter) && <Pressable accessibilityRole="button" onPress={() => setFilter(emptyFilter())} style={styles.clear}>
            <Text style={styles.clearText}>Clear filters</Text>
          </Pressable>}
        </View>
        : <ScrollView horizontal pagingEnabled={false} snapToInterval={columnWidth + 12} decelerationRate="fast"
          showsHorizontalScrollIndicator={false} contentContainerStyle={styles.board}>
          {built.columns.map(column => <View key={column.key} style={[styles.column, { width: columnWidth }]}>
            <Text style={styles.columnTitle}>{column.title} <Text style={styles.columnCount}>{column.count}</Text></Text>
            <ScrollView style={styles.cards} contentContainerStyle={styles.cardsContent} showsVerticalScrollIndicator={false}>
              {column.cards.map(card => <BoardCardView key={`${card.macId}/${card.id}`} card={card} onPress={() => openChat(card)} />)}
              {!column.cards.length && <Text style={styles.columnEmpty}>{column.empty}</Text>}
            </ScrollView>
          </View>)}
        </ScrollView>}
  </View>;
}

function BoardCardView({ card, onPress }: { card: BoardCard; onPress: () => void }) {
  const dimmed = card.archived || card.chat.macState === 'unreachable';
  const meta = [card.projectName, card.agentName, card.macName].filter(Boolean).join(' · ');
  const label = [card.title, meta, card.branch, card.pullRequestLine, `Last activity ${card.age}${card.age === 'now' ? '' : ' ago'}`, card.archived && 'Archived'].filter(Boolean).join(', ');
  return <Pressable accessibilityRole="button" accessibilityLabel={label} onPress={onPress} style={[styles.card, dimmed && { opacity: 0.5 }]}>
    <View style={styles.cardTitleRow}>
      <ProviderLogo provider={card.agentId} size={15} />
      <Text numberOfLines={2} style={styles.cardTitle}>{card.title}</Text>
      {card.pinned && <Text style={styles.pin}>Pinned</Text>}
    </View>
    {!!meta && <Text numberOfLines={1} style={styles.meta}>{meta}</Text>}
    {!!card.branch && <Text numberOfLines={1} style={styles.quiet}>{card.branch}</Text>}
    {!!card.pullRequestLine && <Text numberOfLines={1} style={styles.quiet}>{card.pullRequestLine}</Text>}
    <Text style={styles.quiet}>Last activity {card.age}{card.age === 'now' ? '' : ' ago'}{card.archived ? ' · Archived' : ''}</Text>
  </Pressable>;
}

function BoardFilterMenu({ filter, setFilter, projects, agents, macs }: {
  filter: BoardFilter; setFilter: (next: BoardFilter) => void;
  projects: { key: string; label: string }[]; agents: { key: string; label: string }[]; macs: { key: string; label: string; reachable: boolean }[];
}) {
  const on = (yes: boolean) => (yes ? 'on' : 'off') as 'on' | 'off';
  const toggle = (list: string[], value: string) => list.includes(value) ? list.filter(x => x !== value) : [...list, value];
  const active = isFilterActive({ ...filter, search: '' });
  return <MenuView title="Board" actions={[
    { id: 'projects', title: filter.projects.length ? `Projects (${filter.projects.length})` : 'Projects', subactions: projects.map(p => ({ id: `project:${p.key}`, title: p.label, state: on(filter.projects.includes(p.key)) })) },
    { id: 'agents', title: filter.agents.length ? `Agents (${filter.agents.length})` : 'Agents', subactions: agents.map(a => ({ id: `agent:${a.key}`, title: a.label, state: on(filter.agents.includes(a.key)) })) },
    ...(macs.length > 1 ? [{ id: 'macs', title: filter.macs.length ? `Macs (${filter.macs.length})` : 'Macs', subactions: macs.map(m => ({ id: `mac:${m.key}`, title: m.reachable ? m.label : `${m.label} (unreachable)`, state: on(filter.macs.includes(m.key)) })) }] : []),
    { id: 'archived', title: 'Show Archived Chats', state: on(filter.showArchived) },
    ...(active ? [{ id: 'clear', title: 'Show All Chats' }] : []),
  ]} onPressAction={({ nativeEvent }) => {
    const id = nativeEvent.event, colon = id.indexOf(':');
    const [kind, value] = colon < 0 ? [id, ''] : [id.slice(0, colon), id.slice(colon + 1)];
    if (kind === 'project') setFilter({ ...filter, projects: toggle(filter.projects, value) });
    else if (kind === 'agent') setFilter({ ...filter, agents: toggle(filter.agents, value) });
    else if (kind === 'mac') setFilter({ ...filter, macs: toggle(filter.macs, value) });
    else if (kind === 'archived') setFilter({ ...filter, showArchived: !filter.showArchived });
    else if (kind === 'clear') setFilter({ ...emptyFilter(), search: filter.search });
  }}>
    <View accessibilityRole="button" accessibilityLabel={active ? 'Filter board, some chats are filtered out' : 'Filter board'} style={styles.filterButton}>
      <SymbolView name={{ ios: active ? 'line.3.horizontal.decrease.circle.fill' : 'line.3.horizontal.decrease', android: 'filter_list', web: 'filter_list' } as any} size={17} tintColor={active ? ink : muted} style={{ width: 17, height: 17 }} />
    </View>
  </MenuView>;
}

const styles = StyleSheet.create({
  screen: { flex: 1 },
  toolbar: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 14, paddingTop: 10 },
  search: { flex: 1, height: 38, borderRadius: 10, backgroundColor: inset, paddingHorizontal: 12, justifyContent: 'center' },
  searchInput: { color: ink, fontFamily: 'Inter', fontSize: 14.5, padding: 0 },
  filterButton: { width: 38, height: 38, alignItems: 'center', justifyContent: 'center' },
  summary: { color: tertiary, fontFamily: 'Inter', fontSize: 12.5, paddingHorizontal: 16, paddingTop: 8 },
  unreachable: { color: muted, fontFamily: 'Inter', fontSize: 12.5, paddingHorizontal: 16, paddingTop: 4 },
  board: { paddingHorizontal: 14, paddingTop: 12, paddingBottom: 20, gap: 12 },
  column: { backgroundColor: panel, borderWidth: StyleSheet.hairlineWidth, borderColor: border, borderRadius: 12, padding: 10 },
  columnTitle: { color: ink, fontFamily: 'Inter', fontSize: 14, fontWeight: '600', paddingHorizontal: 4, paddingBottom: 8 },
  columnCount: { color: tertiary, fontWeight: '400' },
  cards: { flexGrow: 0 },
  cardsContent: { gap: 8, paddingBottom: 2 },
  card: { backgroundColor: raised, borderWidth: StyleSheet.hairlineWidth, borderColor: border, borderRadius: 10, padding: 11, gap: 3 },
  cardTitleRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 7 },
  cardTitle: { flex: 1, color: ink, fontFamily: 'Inter', fontSize: 14 },
  pin: { color: tertiary, fontFamily: 'Inter', fontSize: 11 },
  meta: { color: muted, fontFamily: 'Inter', fontSize: 12 },
  quiet: { color: tertiary, fontFamily: 'Inter', fontSize: 12 },
  columnEmpty: { color: tertiary, fontFamily: 'Inter', fontSize: 12.5, paddingHorizontal: 4, paddingVertical: 6 },
  empty: { color: muted, fontFamily: 'Inter', fontSize: 13, margin: 18 },
  clear: { marginHorizontal: 18 },
  clearText: { color: ink, fontFamily: 'Inter', fontSize: 13, fontWeight: '600' },
});
