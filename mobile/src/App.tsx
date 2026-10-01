import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Alert, AppState, FlatList, KeyboardAvoidingView, Linking, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View, type ScrollViewProps } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { SafeAreaProvider, SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import * as Haptics from 'expo-haptics';
import { useFonts } from 'expo-font';
import { SymbolView } from 'expo-symbols';
import Svg, { Path } from 'react-native-svg';
import { MenuView } from '@react-native-menu/menu';
import { BlurTargetView } from 'expo-blur';
import { useHeaderHeight } from '@react-navigation/elements';
import { remote } from './remote';
import { ChatWorkspace } from './ChatWorkspace';
import { PullRequestIcon } from './PullRequestIcon';
import { FileIcon } from './FileIcon';
import { SwipeForward } from './SwipeForward';
import { useKeyboardHeight } from './useKeyboardVisible';
import { NativeSelect } from './NativeSelect';
import { ProviderLogo, providerMenuImage } from './ProviderLogo';
import { KeyboardAwareScrollView } from './KeyboardAwareScrollView';
import { ProgressiveBlur } from './ProgressiveBlur';
import { SyntaxCode, highlightDiffLines } from './SyntaxCode';
import { TerminalView } from './TerminalView';
import { SettingsScreen } from './SettingsScreen';
import { uuid } from './secure';
import { attachmentPayload, pickAttachments, type PickedAttachment } from './attachments';
import { displayDate, swiftDate, type Automation, type AutomationTrigger, type Project, type Session } from './types';

// Graphite values come from Abstract/Theme/Palette.swift.
const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E';
const bg = '#1E1E21', sidebar = '#19191C', panel = '#252529', raised = '#2B2B30', inset = '#303036';
const accent = ink, border = 'rgba(255,255,255,0.075)';
const Stack = createNativeStackNavigator();

type IconName = 'menu' | 'back' | 'plus' | 'clock' | 'branch' | 'pull' | 'devices' | 'folder' | 'chat' | 'review' | 'files' | 'terminal' | 'settings' | 'chevron' | 'close' | 'refresh' | 'check' | 'failed' | 'pending' | 'skipped' | 'filter';
const symbols: Record<IconName, { ios: string; android: string; web: string }> = {
  menu: { ios: 'sidebar.left', android: 'menu', web: 'menu' },
  back: { ios: 'chevron.left', android: 'arrow_back', web: 'arrow_back' },
  plus: { ios: 'plus', android: 'add', web: 'add' },
  clock: { ios: 'clock.arrow.circlepath', android: 'schedule', web: 'schedule' },
  branch: { ios: 'point.3.connected.trianglepath.dotted', android: 'account_tree', web: 'account_tree' },
  pull: { ios: 'point.3.filled.connected.trianglepath.dotted', android: 'merge', web: 'merge' },
  devices: { ios: 'laptopcomputer', android: 'laptop_mac', web: 'laptop_mac' },
  folder: { ios: 'folder', android: 'folder', web: 'folder' },
  chat: { ios: 'bubble.left', android: 'chat_bubble', web: 'chat_bubble' },
  review: { ios: 'plusminus', android: 'difference', web: 'difference' },
  files: { ios: 'doc.text', android: 'description', web: 'description' },
  terminal: { ios: 'terminal', android: 'terminal', web: 'terminal' },
  settings: { ios: 'gearshape', android: 'settings', web: 'settings' },
  chevron: { ios: 'chevron.right', android: 'chevron_right', web: 'chevron_right' },
  close: { ios: 'xmark', android: 'close', web: 'close' },
  refresh: { ios: 'arrow.clockwise', android: 'refresh', web: 'refresh' },
  check: { ios: 'checkmark', android: 'check', web: 'check' },
  failed: { ios: 'xmark', android: 'close', web: 'close' },
  pending: { ios: 'clock', android: 'schedule', web: 'schedule' },
  skipped: { ios: 'minus', android: 'remove', web: 'remove' },
  filter: { ios: 'line.3.horizontal.decrease', android: 'filter_list', web: 'filter_list' }
};
function Icon({ name, size = 19, color = muted }: { name: IconName; size?: number; color?: string }) {
  return <SymbolView name={symbols[name] as any} size={size} tintColor={color} style={{ width: size, height: size }} />;
}

function useRemote() {
  const [, rerender] = useState(0);
  useEffect(() => remote.subscribe(() => rerender(x => x + 1)), []);
  return remote;
}
function Button({ title, onPress, secondary, danger }: { title: string; onPress: () => void; secondary?: boolean; danger?: boolean }) {
  return <Pressable onPress={() => { Haptics.selectionAsync().catch(() => {}); onPress(); }} style={[styles.button, secondary && styles.secondary, danger && styles.danger]}><Text style={[styles.buttonText, secondary && { color: ink }]}>{title}</Text></Pressable>;
}
function ReviewFileButton({ title, destructive, onPress }: { title: string; destructive?: boolean; onPress: () => void }) {
  const color = destructive ? '#EF8582' : '#8EDBAD';
  return <Pressable accessibilityRole="button" accessibilityLabel={title} onPress={() => { Haptics.selectionAsync().catch(() => {}); onPress(); }} style={({ pressed }) => [styles.reviewFileButton, destructive ? styles.reviewFileButtonDiscard : styles.reviewFileButtonApply, pressed && styles.reviewFileButtonPressed]}>
    <SymbolView name={{ ios: destructive ? 'trash' : 'checkmark.circle', android: destructive ? 'delete_outline' : 'check_circle' }} size={16} tintColor={color} />
    <Text style={[styles.reviewFileButtonText, { color }]}>{title}</Text>
  </Pressable>;
}
type PRButtonKind = 'primary' | 'secondary';
function PRButtonFace({ title, kind = 'secondary', disabled, loading }: { title: string; kind?: PRButtonKind; disabled?: boolean; loading?: boolean }) {
  return <View style={[styles.prButton, kind === 'primary' && styles.prButtonPrimary, disabled && styles.prButtonDisabled]}>
    {loading && <ActivityIndicator size="small" color={kind === 'primary' ? bg : ink} />}
    <Text style={[styles.prButtonText, kind === 'primary' && styles.prButtonTextPrimary]}>{title}</Text>
  </View>;
}
function PRButton({ title, onPress, kind = 'secondary', disabled, loading, accessibilityLabel }: { title: string; onPress: () => void; kind?: PRButtonKind; disabled?: boolean; loading?: boolean; accessibilityLabel?: string }) {
  return <Pressable accessibilityRole="button" accessibilityLabel={accessibilityLabel || title} accessibilityState={{ disabled: !!disabled, busy: !!loading }} disabled={disabled} onPress={() => { Haptics.selectionAsync().catch(() => {}); onPress(); }}><PRButtonFace title={title} kind={kind} disabled={disabled} loading={loading} /></Pressable>;
}
function Row({ title, subtitle, onPress, trailing, icon, iconNode }: { title: string; subtitle?: string; onPress: () => void; trailing?: string; icon?: IconName; iconNode?: React.ReactNode }) {
  return <Pressable onPress={onPress} style={styles.row}>{iconNode || (icon && <Icon name={icon} size={15} color={tertiary} />)}<View style={{ flex: 1 }}><Text style={styles.rowTitle}>{title}</Text>{subtitle ? <Text style={styles.subtitle}>{subtitle}</Text> : null}</View>{trailing ? <Text style={styles.trailing}>{trailing}</Text> : <Icon name="chevron" size={12} color={tertiary} />}</Pressable>;
}
function Section({ title, children, iconNode }: { title: string; children: React.ReactNode; iconNode?: React.ReactNode }) {
  return <View style={styles.section}><View style={{ flexDirection: 'row', alignItems: 'center', gap: 7 }}>{iconNode}<Text style={styles.sectionTitle}>{title}</Text></View>{children}</View>;
}
function PaneSection({ title, detail, children }: { title: string; detail?: string; children: React.ReactNode }) {
  return <View style={styles.paneSection}><View style={styles.paneSectionHeader}><Text style={styles.paneSectionTitle}>{title}</Text>{detail ? <Text style={styles.paneSectionDetail}>{detail}</Text> : null}</View>{children}</View>;
}
function Empty({ text }: { text: string }) { return <Text style={styles.empty}>{text}</Text>; }
function HeaderScrollView({ keyboardAware, contentContainerStyle, ...props }: ScrollViewProps & { keyboardAware?: boolean }) {
  const headerHeight = useHeaderHeight();
  const contentStyle = StyleSheet.flatten(contentContainerStyle);
  const existingTop = contentStyle?.paddingTop ?? contentStyle?.paddingVertical ?? contentStyle?.padding;
  const padded = [contentContainerStyle, { paddingTop: headerHeight + (typeof existingTop === 'number' ? existingTop : 0) }];
  return keyboardAware ? <KeyboardAwareScrollView {...props} contentContainerStyle={padded} /> : <ScrollView {...props} contentContainerStyle={padded} />;
}
function HeaderSpacer() {
  return <View style={{ height: useHeaderHeight() }} />;
}
function run(action: () => Promise<unknown>) { action().catch(error => Alert.alert('Abstract', String(error.message || error))); }
function activeRoot(session: Session) { return session.worktreePath || remote.snapshot?.projects.find(x => x.id === session.projectId)?.rootPath || ''; }

function RailAction({ icon, title, detail, onPress }: { icon: IconName; title: string; detail?: string; onPress: () => void }) {
  return <Pressable accessibilityRole="button" onPress={onPress} style={styles.railAction}>
    {icon === 'pull' ? <PullRequestIcon size={18} color={muted} /> : <Icon name={icon} size={18} />}<Text numberOfLines={1} style={styles.railActionTitle}>{title}</Text>
    {detail ? <Text style={styles.railDetail}>{detail}</Text> : null}
  </Pressable>;
}
function WorkspaceRail({ navigate, selectedChat }: { navigate: (name: string, params?: Record<string, unknown>) => void; selectedChat?: string | null }) {
  const state = useRemote();
  const projects = state.snapshot?.projects || [];
  const sessions = state.snapshot?.sessions.filter(x => !x.archivedAt) || [];
  const standalone = sessions.filter(x => !x.projectId);
  const prs = Object.keys(state.snapshot?.pullRequests || {}).length;
  return <View style={styles.rail}>
    <HeaderScrollView contentContainerStyle={styles.railContent}>
      <RailAction icon="plus" title="New" onPress={() => navigate('NewChat', {})} />
      <RailAction icon="clock" title="Automations" onPress={() => navigate('Automations')} />
      <RailAction icon="branch" title="Worktrees" onPress={() => navigate('Worktrees')} />
      <RailAction icon="pull" title="Pull Requests" detail={prs ? String(prs) : undefined} onPress={() => navigate('PullRequests')} />
      {state.active && <Pressable onPress={() => navigate('Settings')} style={styles.railHost}><Icon name="devices" size={14} color={tertiary} /><Text numberOfLines={1} style={styles.railHostTitle}>{state.active.peer.name}</Text><View style={[styles.connectionDot, state.status !== 'online' && { backgroundColor: tertiary }]} /></Pressable>}
      {projects.map(project => <View key={project.id} style={styles.railGroup}>
        <Pressable onPress={() => navigate('Project', { projectId: project.id })} style={styles.railGroupHeader}>
          <Text numberOfLines={1} style={styles.railGroupTitle}>{project.name}</Text><Icon name="chevron" size={12} color={tertiary} />
        </Pressable>
        {sessions.filter(x => x.projectId === project.id).sort((a, b) => b.createdAt - a.createdAt).map(chat => <Pressable key={chat.id} onPress={() => navigate('Chat', { sessionId: chat.id })} style={[styles.railChat, selectedChat === chat.id && styles.railChatSelected]}>
          {state.snapshot?.pullRequests?.[chat.id] ? <PullRequestIcon pr={state.snapshot.pullRequests[chat.id]} size={13} /> : <View style={[styles.statusDiamond, chat.status === 'running' && styles.statusRunning]} />}<Text numberOfLines={1} style={styles.railChatTitle}>{chat.name}</Text>
          {chat.status === 'running' ? <Text style={styles.railDetail}>•••</Text> : null}
        </Pressable>)}
      </View>)}
      {standalone.length > 0 && <View style={styles.railGroup}><Text style={styles.railGroupTitle}>Standalone</Text>{standalone.map(chat => <Pressable key={chat.id} onPress={() => navigate('Chat', { sessionId: chat.id })} style={[styles.railChat, selectedChat === chat.id && styles.railChatSelected]}>{state.snapshot?.pullRequests?.[chat.id] ? <PullRequestIcon pr={state.snapshot.pullRequests[chat.id]} size={13} /> : <View style={styles.statusDiamond} />}<Text numberOfLines={1} style={styles.railChatTitle}>{chat.name}</Text></Pressable>)}</View>}
      {!state.snapshot && <Text style={styles.railEmpty}>Connect to a Mac to see its projects and chats.</Text>}
    </HeaderScrollView>
    <Pressable onPress={() => navigate('Settings')} style={styles.railFooter}><Icon name="settings" /><Text numberOfLines={1} style={styles.railFooterTitle}>Settings</Text><Text numberOfLines={1} style={styles.railDetail}>{state.status === 'online' ? 'Connected' : state.status === 'connecting' ? 'Connecting' : 'Offline'}</Text><View style={[styles.connectionDot, state.status !== 'online' && { backgroundColor: tertiary }]} /></Pressable>
  </View>;
}
function SidebarScreen({ navigation, route }: any) {
  const state = useRemote();
  const selected = route.params?.selectedChat as string | undefined;
  const latest = state.snapshot?.sessions.filter(chat => !chat.archivedAt).sort((a, b) => b.createdAt - a.createdAt)[0]?.id;
  useEffect(() => {
    navigation.setOptions({
      headerLeft: () => <Pressable accessibilityRole="button" accessibilityLabel="Close sidebar" onPress={() => { if (selected || latest) navigation.navigate('Chat', { sessionId: selected || latest }); }} style={styles.headerAction}><Icon name="close" size={19} color={ink} /></Pressable>,
    });
  }, [navigation, selected, latest]);
  return <SafeAreaView edges={['bottom', 'left', 'right']} style={{ flex: 1, backgroundColor: sidebar }}>
    <SwipeForward enabled={!!(selected || latest)} onSwipe={() => navigation.navigate('Chat', { sessionId: selected || latest })}>
      <WorkspaceRail navigate={(name, params) => navigation.navigate(name, params)} selectedChat={selected} />
    </SwipeForward>
  </SafeAreaView>;
}
function ScreenNavigation({ navigation }: { navigation: any }) {
  return <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
    {navigation.canGoBack() && <Pressable accessibilityLabel="Back" onPress={() => navigation.goBack()} style={styles.headerAction}><Icon name="back" size={17} color={ink} /></Pressable>}
    <Pressable accessibilityLabel="Open sidebar" onPress={() => navigation.popTo('Sidebar')} style={styles.headerAction}><Icon name="menu" size={19} color={ink} /></Pressable>
  </View>;
}
function PullRequestsScreen({ navigation }: any) {
  const state = useRemote();
  const prs = Object.entries(state.snapshot?.pullRequests || {});
  return <HeaderScrollView style={styles.page} contentContainerStyle={styles.content}>
    <Text style={styles.title}>Pull Requests</Text>
    {prs.map(([sessionId, pr]) => <Pressable key={sessionId} style={styles.row} onPress={() => navigation.navigate('PullRequest', { sessionId })}><PullRequestIcon pr={pr} /><View style={{ flex: 1 }}><Text style={styles.rowTitle} numberOfLines={1}>{`#${pr.number}  ${pr.title}`}</Text><Text style={styles.subtitle}>{`${pr.standing || (pr.isDraft ? 'Draft' : pr.state)} · ${state.snapshot?.sessions.find(x => x.id === sessionId)?.name || ''}`}</Text></View><Icon name="chevron" size={12} /></Pressable>)}
    {!prs.length && <Empty text="No pull requests on this Mac." />}
  </HeaderScrollView>;
}

function ProjectsScreen({ navigation }: any) {
  const state = useRemote();
  return <HeaderScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Projects</Text><Text style={styles.lead}>{state.active?.peer.name || 'Connect a Mac to see its projects'}</Text>
    {(state.snapshot?.projects || []).map(project => <Row key={project.id} title={project.name} subtitle={project.rootPath} onPress={() => navigation.navigate('Project', { projectId: project.id })} />)}
    {!state.snapshot?.projects.length && <Empty text="No projects available." />}
  </HeaderScrollView>;
}
function ProjectScreen({ route, navigation }: any) {
  const state = useRemote();
  const project = state.snapshot?.projects.find(x => x.id === route.params.projectId) as Project | undefined;
  if (!project) return <View style={styles.content}><Empty text="Project unavailable." /></View>;
  const chats = state.snapshot?.sessions.filter(x => x.projectId === project.id && !x.archivedAt) || [];
  return <HeaderScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>{project.name}</Text><Text style={styles.lead}>{project.rootPath}</Text>
    <View style={styles.actions}><Button title="New chat" onPress={() => navigation.navigate('NewChat', { projectId: project.id })} /><Button title="Worktrees" secondary onPress={() => navigation.navigate('Worktrees', { projectId: project.id })} /><Button title="Files" secondary onPress={() => navigation.navigate('Files', { root: project.rootPath })} /><Button title="Terminal" secondary onPress={() => navigation.navigate('Terminal', { root: project.rootPath })} /></View>
    <Section title="Chats">{chats.map(chat => <Row key={chat.id} title={chat.name} subtitle={`${chat.providerId} · ${chat.branch || chat.status}`} iconNode={<ProviderLogo provider={chat.providerId} size={16} />} onPress={() => navigation.navigate('Chat', { sessionId: chat.id })} trailing={chat.status} />)}{!chats.length && <Empty text="No chats in this project." />}</Section>
  </HeaderScrollView>;
}
function ChatsScreen({ navigation }: any) {
  const state = useRemote();
  const chats = state.snapshot?.sessions.filter(x => !x.archivedAt).sort((a, b) => b.createdAt - a.createdAt) || [];
  return <HeaderScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Chats</Text><Text style={styles.lead}>{state.active?.peer.name || 'Connect a Mac to see its chats'}</Text>{state.snapshot && <Button title="New standalone chat" onPress={() => navigation.navigate('NewChat', { standalone: true })} />}
    {chats.map(chat => <Row key={chat.id} title={chat.name} subtitle={`${state.snapshot?.projects.find(p => p.id === chat.projectId)?.name || 'No project'} · ${chat.providerId}`} iconNode={<ProviderLogo provider={chat.providerId} size={16} />} trailing={chat.status} onPress={() => navigation.navigate('Chat', { sessionId: chat.id })} />)}
    {!chats.length && <Empty text="No chats available." />}
  </HeaderScrollView>;
}
type LauncherChoice = { id: string; title: string; selected?: boolean; image?: string };
function LauncherPicker({ label, value, choices, onSelect, leading }: { label: string; value: string; choices: LauncherChoice[]; onSelect: (id: string) => void; leading?: React.ReactNode }) {
  return <MenuView title={label} actions={choices.map(choice => ({ id: choice.id, title: choice.title, state: choice.selected ? 'on' : 'off', image: choice.image }))} onPressAction={({ nativeEvent }) => onSelect(nativeEvent.event)}>
    <View accessibilityRole="button" accessibilityLabel={`${label}: ${value}`} style={styles.launcherPicker}>{leading}<Text numberOfLines={1} style={styles.launcherPickerText}>{value}</Text><SymbolView name={{ ios: 'chevron.down', android: 'keyboard_arrow_down' }} size={10} tintColor={tertiary} /></View>
  </MenuView>;
}
function BrandMark() {
  return <Svg width={44} height={44} viewBox="0 0 100 100" accessibilityLabel="Abstract">
    <Path fill={ink} d="M93.67,50c-0.4,9-8.84,14.39-15.12,19.54-6.08,5-10.27,11.3-15.62,17-7.09,7.51-15.66,9.2-23.62,1.85-5.69-5.25-9.59-12.08-15.48-17.16S9.3,61.23,7.17,53.25C4.73,44.13,13,37.56,19.28,32.53S30.14,22,35.27,16C41.18,9,49.1,3.23,58,9.13,65.36,14,69.51,22.59,76.1,28.4,82.85,34.34,93.22,39.95,93.67,50c0.09,1.92,3.09,1.93,3,0-0.43-9.53-8.15-15.31-15-20.84C74.09,23,69.22,14.46,61.78,8.27,55.37,2.93,47.38,2,40.4,6.88,32.57,12.37,28,21.39,20.73,27.51,14.33,32.87,5.7,38.28,4,47.13c-1.74,9.11,5.18,15.93,11.6,21.2,3.6,3,7.34,5.74,10.47,9.22s6,7.57,9.28,11.07C41,94.63,48.71,98.71,56.86,95c9.45-4.35,14.2-15.05,21.84-21.65C86.18,66.85,96.18,61,96.67,50,96.76,48.07,93.76,48.07,93.67,50Z" />
  </Svg>;
}
function NewChatScreen({ route, navigation }: any) {
  const state = useRemote();
  const [prompt, setPrompt] = useState('');
  const [attachments, setAttachments] = useState<PickedAttachment[]>([]);
  const [projectId, setProjectId] = useState<string | null>(route.params?.projectId || null);
  const [standalone, setStandalone] = useState(!!route.params?.standalone);
  const project = state.snapshot?.projects.find(x => x.id === projectId);
  const [provider, setProvider] = useState('claude');
  const [modelName, setModelName] = useState('');
  const [customModel, setCustomModel] = useState(false);
  const [effort, setEffort] = useState('');
  const [policy, setPolicy] = useState<'ask' | 'auto-edits' | 'bypass'>('ask');
  const [base, setBase] = useState('HEAD');
  const [worktree, setWorktree] = useState(route.params?.worktree || '');
  const [worktrees, setWorktrees] = useState<Array<{ path: string; branch: string }>>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!projectId && !standalone && state.snapshot?.projects.length) setProjectId(state.snapshot.projects[0].id);
  }, [projectId, standalone, state.snapshot?.projects]);
  useEffect(() => {
    if (!project) return;
    setProvider(project.defaultProviderId);
    setPolicy(project.defaultPermissionPolicy);
    setBase(project.defaultBaseRef || 'HEAD');
  }, [project?.id]);
  useEffect(() => {
    if (!project && state.snapshot?.providers.length && !state.snapshot.providers.includes(provider)) {
      setProvider(state.snapshot.providers[0]);
      setModelName('');
      setEffort('');
    }
  }, [project?.id, provider, state.snapshot?.providers]);
  useEffect(() => {
    if (!project) { setWorktrees([]); return; }
    let active = true;
    state.exec(project.rootPath, ['worktree', 'list', '--porcelain']).then(result => {
      if (!active || result.code !== 0) return;
      const entries = result.stdout.split(/\n\n+/).map(block => ({ path: block.match(/^worktree (.*)$/m)?.[1] || '', branch: block.match(/^branch refs\/heads\/(.*)$/m)?.[1] || '' }));
      setWorktrees(entries.filter(entry => entry.path && entry.path !== project.rootPath));
    }).catch(() => { if (active) setWorktrees([]); });
    return () => { active = false; };
  }, [project?.id]);
  const catalog = state.snapshot?.modelCatalogs?.[provider];
  const modelOption = [...(catalog?.models || []), ...(catalog?.versions || [])].find(x => x.id === modelName);
  const effortLevels = modelOption?.efforts || catalog?.accountDefault?.efforts || [];
  const providerLabel = (id: string) => ({ claude: 'Claude Code', codex: 'Codex', opencode: 'OpenCode' } as Record<string, string>)[id] || id;
  const policyLabels = { ask: 'Ask before acting', 'auto-edits': 'Accept edits', bypass: 'Full autonomy' };
  const selectedWorktree = worktrees.find(x => x.path === worktree);
  const worktreeLabel = selectedWorktree?.branch || (worktree ? worktree.split('/').pop() || worktree : 'New worktree');
  const worktreeHolder = worktree && state.snapshot?.sessions.find(x => x.worktreePath === worktree && !x.archivedAt);
  const canStart = !busy && state.status === 'online' && !!state.snapshot?.providers.includes(provider) && (!!project || standalone || !state.snapshot?.projects.length) && (!!prompt.trim() || attachments.length > 0);
  const submit = async () => {
    if (!canStart) return;
    setBusy(true);
    try {
      const response = project
        ? await state.request('startChat', { _0: { projectId: project.id, providerId: provider, prompt: prompt.trim(), ...attachmentPayload(attachments), baseRef: base || null, policy, model: modelName || null, effort: effort || null, worktree: worktree || null } })
        : await state.request('startStandaloneConfigured', { providerId: provider, prompt: prompt.trim(), policy,
          ...attachmentPayload(attachments), model: modelName || null, effort: effort || null });
      navigation.replace('Chat', { sessionId: response.started?.sessionId });
    } catch (error) { Alert.alert('Could not start chat', String(error)); } finally { setBusy(false); }
  };
  const recent = (state.snapshot?.sessions || []).filter(x => !x.archivedAt).sort((a, b) => b.createdAt - a.createdAt).slice(0, 6);
  return <HeaderScrollView keyboardAware style={styles.page} contentContainerStyle={styles.launcherContent}>
    <View style={styles.launcherIntro}><BrandMark /><Text style={styles.launcherTitle}>{state.snapshot?.projects.length ? 'What should we build?' : 'Welcome to Abstract'}</Text><Text style={styles.launcherDescription}>{state.snapshot?.projects.length ? 'Each chat runs its own agent in an isolated worktree, so several can work at once without stepping on each other.' : 'Connect a Mac and start a standalone chat, or add a project on your Mac to work in isolated worktrees.'}</Text></View>
    <View style={styles.launcherBox}>
      <TextInput autoFocus={!!state.snapshot?.projects.length} style={styles.launcherPrompt} value={prompt} onChangeText={setPrompt} multiline textAlignVertical="top" placeholder="Describe the task. Be as specific as you would with a colleague." placeholderTextColor={tertiary} />
      {attachments.length > 0 && <View style={styles.launcherAttachments}>{attachments.map(item => <Pressable key={item.id} accessibilityRole="button" accessibilityLabel={`Remove ${item.title}`} onPress={() => setAttachments(attachments.filter(x => x.id !== item.id))} style={styles.launcherAttachment}><Text numberOfLines={1} style={styles.launcherPickerText}>{item.title} ×</Text></Pressable>)}</View>}
      <View style={styles.launcherControls}>
        <Pressable accessibilityRole="button" accessibilityLabel="Attach files or images" onPress={() => run(async () => setAttachments(await pickAttachments(attachments)))} style={styles.launcherPicker}><Icon name="plus" size={16} color={muted} /></Pressable>
        <LauncherPicker label="Project" value={project?.name || 'No project'} choices={[...(state.snapshot?.projects || []).map(x => ({ id: x.id, title: x.name, selected: x.id === projectId })), { id: '', title: 'No project', selected: !projectId }]} onSelect={id => { setStandalone(!id); setProjectId(id || null); setWorktree(''); }} />
        <LauncherPicker label="Agent" value={providerLabel(provider)} leading={<ProviderLogo provider={provider} size={13} />} choices={(state.snapshot?.providers || []).map(id => ({ id, title: providerLabel(id), selected: id === provider, image: Platform.OS === 'ios' ? providerMenuImage(id) : undefined }))} onSelect={id => { setProvider(id); setModelName(''); setEffort(''); setCustomModel(false); }} />
        <LauncherPicker label="Model" value={modelOption?.label || modelName || state.snapshot?.defaultModelNames?.[provider] || 'Default model'} choices={[{ id: '', title: 'Default model', selected: !modelName }, ...(catalog?.models || []).map(x => ({ id: x.id, title: x.label, selected: modelName === x.id })), ...(catalog?.versions || []).map(x => ({ id: x.id, title: x.label, selected: modelName === x.id })), { id: '__other__', title: 'Other Model…' }]} onSelect={id => { if (id === '__other__') setCustomModel(true); else { setModelName(id); setEffort(''); setCustomModel(false); } }} />
        {effortLevels.length > 0 && <LauncherPicker label="Reasoning effort" value={effort ? effort.replace(/^./, x => x.toUpperCase()) : 'Default effort'} choices={[{ id: '', title: 'Default effort', selected: !effort }, ...effortLevels.map(id => ({ id, title: id.replace(/^./, x => x.toUpperCase()), selected: effort === id }))]} onSelect={setEffort} />}
        <LauncherPicker label="Permissions" value={policyLabels[policy]} choices={(['ask', 'auto-edits', 'bypass'] as const).map(id => ({ id, title: policyLabels[id], selected: id === policy }))} onSelect={id => setPolicy(id as typeof policy)} />
        {project && <><LauncherPicker label="Worktree" value={worktreeLabel} choices={[{ id: '', title: 'New worktree', selected: !worktree }, ...worktrees.map(x => ({ id: x.path, title: x.branch || x.path.split('/').pop() || x.path, selected: x.path === worktree }))]} onSelect={setWorktree} />{!worktree && <View style={styles.launcherBase}><Text style={styles.launcherBaseLabel}>from</Text><TextInput style={styles.launcherBaseInput} value={base} onChangeText={setBase} autoCapitalize="none" autoCorrect={false} placeholder="HEAD" placeholderTextColor={tertiary} /></View>}</>}
      </View>
      {customModel && <TextInput autoFocus style={styles.launcherCustomModel} value={modelName} onChangeText={value => { setModelName(value); setEffort(''); }} autoCapitalize="none" autoCorrect={false} placeholder="Model name" placeholderTextColor={tertiary} />}
      {worktreeHolder && <Text style={styles.launcherWarning}>“{worktreeHolder.name}” works here now. Starting stops its agent and this chat takes the worktree.</Text>}
      <View style={styles.launcherFooter}><Pressable accessibilityRole="button" accessibilityState={{ disabled: !canStart }} disabled={!canStart} onPress={() => run(submit)} style={[styles.launcherStart, !canStart && styles.launcherStartDisabled]}><Text style={styles.launcherStartText}>{busy ? 'Starting…' : 'Start'}</Text><Icon name="chevron" size={13} color={bg} /></Pressable></View>
    </View>
    {recent.length > 0 && <View style={styles.launcherRecent}><Text style={styles.launcherRecentLabel}>Recent</Text>{recent.map(chat => <Pressable key={chat.id} onPress={() => navigation.navigate('Chat', { sessionId: chat.id })} style={styles.launcherRecentRow}><ProviderLogo provider={chat.providerId} size={15} /><Text numberOfLines={1} style={styles.launcherRecentName}>{chat.name}</Text><Text numberOfLines={1} style={styles.launcherRecentMeta}>{state.snapshot?.projects.find(x => x.id === chat.projectId)?.name || 'Standalone'}</Text></Pressable>)}</View>}
  </HeaderScrollView>;
}
function WorktreesScreen({ route, navigation }: any) {
  const state = useRemote(); const project = state.snapshot?.projects.find(x => x.id === route.params?.projectId);
  const [output, setOutput] = useState('');
  const refresh = () => { if (project) state.exec(project.rootPath, ['worktree', 'list', '--porcelain']).then(x => setOutput(x.stdout)).catch(error => setOutput(String(error))); };
  useEffect(refresh, [project?.id]);
  const entries = output.split(/\n\n+/).map(block => ({ path: block.match(/^worktree (.*)$/m)?.[1], branch: block.match(/^branch refs\/heads\/(.*)$/m)?.[1] })).filter(x => x.path);
  return <HeaderScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Worktrees</Text>{!project ? <Section title="Projects">{state.snapshot?.projects.map(p => <Row key={p.id} title={p.name} subtitle={p.rootPath} onPress={() => navigation.navigate('Worktrees', { projectId: p.id })} />)}</Section> : <><Text style={styles.lead}>{project.name}</Text>{entries.map(entry => <View key={entry.path}><Row title={entry.branch || 'Detached'} subtitle={entry.path} onPress={() => navigation.navigate('Files', { root: entry.path })} /><Button title="Terminal" secondary onPress={() => navigation.navigate('Terminal', { root: entry.path })} />{entry.path !== project.rootPath && <><Button title="New chat here" secondary onPress={() => navigation.navigate('NewChat', { projectId: project.id, worktree: entry.path })} /><Button title="Remove worktree" danger onPress={() => Alert.alert('Remove worktree?', entry.path || '', [{ text: 'Cancel' }, { text: 'Remove', style: 'destructive', onPress: () => run(async () => { await state.request('removeWorktree', { projectId: project.id, path: entry.path, deleteBranch: false }); refresh(); }) }])} /></>}</View>)}{!entries.length && <Empty text="No worktrees found." />}</>}
    <Text style={styles.hint}>Create a chat to create a new worktree. Open a worktree to browse its files.</Text>
  </HeaderScrollView>;
}
function FilesScreen({ route, navigation }: any) {
  const state = useRemote(); const root = route.params.root as string;
  const [paths, setPaths] = useState<string[]>([]); const [query, setQuery] = useState(''); const [folder, setFolder] = useState('');
  const [error, setError] = useState(''); const [loading, setLoading] = useState(false);
  const refresh = () => { setLoading(true); setError(''); state.request('listFiles', { root }).then(response => setPaths(response.files?._0 || [])).catch(reason => setError(String(reason.message || reason))).finally(() => setLoading(false)); };
  useEffect(() => { refresh(); }, [root]);
  const matchingPaths = query.trim() ? paths.filter(path => path.toLowerCase().includes(query.trim().toLowerCase())) : null;
  const entries = matchingPaths
    ? matchingPaths.slice(0, 500).map(path => ({ path, name: path.split('/').at(-1) || path, directory: false }))
    : [...new Map(paths.filter(path => path.startsWith(folder ? `${folder}/` : '')).map(path => {
        const remainder = path.slice(folder ? folder.length + 1 : 0);
        const name = remainder.split('/')[0];
        const directory = remainder.includes('/');
        const child = folder ? `${folder}/${name}` : name;
        return [child, { path: child, name, directory }] as const;
      })).values()].sort((a, b) => Number(b.directory) - Number(a.directory) || a.name.localeCompare(b.name));
  return <SwipeForward enabled={!!route.params.sessionId} onSwipe={() => navigation.navigate('Terminal', { root, sessionId: route.params.sessionId })} onBack={() => navigation.goBack()}><View style={styles.page}>
    <HeaderSpacer />
    <View style={styles.filesFilterSection}>
      <View style={styles.filesFilterHeading}><Text style={styles.filesFilterTitle}>FILES</Text><Text style={styles.filesFilterCount}>{loading ? 'Loading…' : matchingPaths ? `${matchingPaths.length} matches` : `${entries.length} items`}</Text></View>
      <View style={styles.filesFilterRow}><View style={styles.fileFilter}><Icon name="filter" size={16} color={tertiary} /><TextInput style={styles.fileFilterInput} placeholder="Filter files" placeholderTextColor={tertiary} value={query} onChangeText={setQuery} autoCapitalize="none" autoCorrect={false} />{query ? <Pressable style={styles.fileFilterClear} onPress={() => setQuery('')} accessibilityLabel="Clear filter"><Icon name="close" size={13} color={muted} /></Pressable> : null}</View><Pressable style={styles.fileRefreshButton} accessibilityLabel="Refresh files" onPress={() => { Haptics.selectionAsync().catch(() => {}); refresh(); }}><Icon name="refresh" size={17} color={muted} /></Pressable></View>
    </View>
    {folder ? <Pressable style={styles.breadcrumb} onPress={() => setFolder(folder.split('/').slice(0, -1).join('/'))}><Icon name="back" size={13} color={muted} /><Text numberOfLines={1} style={styles.breadcrumbText}>{folder}</Text></Pressable> : null}
    {error ? <View style={styles.paneEmpty}><Icon name="failed" size={22} color="#EF6461" /><Text style={styles.paneEmptyTitle}>Couldn't load files</Text><Text style={styles.empty}>{error}</Text><Button title="Try again" secondary onPress={refresh} /></View> : loading && !paths.length ? <View style={styles.paneEmpty}><Text style={styles.empty}>Loading files…</Text></View> : <FlatList contentContainerStyle={styles.fileList} data={entries} keyExtractor={item => item.path} ListEmptyComponent={<View style={styles.paneEmpty}><Text style={styles.empty}>{query.trim() ? 'No matching files.' : 'No files found.'}</Text></View>} renderItem={({ item }) => <Pressable style={styles.fileTreeRow} onPress={() => item.directory ? setFolder(item.path) : navigation.navigate('File', { path: root.replace(/\/$/, '') + '/' + item.path })}><FileIcon path={item.path} directory={item.directory} size={17} /><View style={{ flex: 1, minWidth: 0 }}><Text numberOfLines={1} style={styles.fileTreeTitle}>{item.name}</Text>{query ? <Text numberOfLines={1} style={styles.fileTreeSubtitle}>{item.path}</Text> : null}</View>{item.directory ? <Icon name="chevron" size={11} color={tertiary} /> : null}</Pressable>} />}
  </View></SwipeForward>;
}
function FileScreen({ route, navigation }: any) {
  const state = useRemote(); const path = route.params.path as string;
  const [content, setContent] = useState(''); const [editing, setEditing] = useState(false);
  useEffect(() => { state.readFile(path).then(setContent).catch(error => Alert.alert('File', String(error))); }, [path]);
  useEffect(() => { navigation.setOptions({ title: path.split('/').at(-1) || 'File' }); }, [navigation, path]);
  const save = async () => { await state.writeFile(path, content); setEditing(false); };
  const lines = content.split('\n');
  return <KeyboardAvoidingView style={styles.page} behavior={Platform.OS === 'ios' ? 'padding' : undefined}><HeaderSpacer /><View style={styles.paneToolbar}><FileIcon path={path} size={16} /><Text style={styles.editorMeta}>{content.length} characters · {lines.length} lines{editing ? ' · Editing' : ''}</Text><View style={{ flex: 1 }} /><Pressable style={styles.editorAction} onPress={() => editing ? run(save) : setEditing(true)}><Text style={styles.editorActionText}>{editing ? 'Save' : 'Edit'}</Text></Pressable>{editing && <Pressable style={styles.editorAction} onPress={() => { setEditing(false); state.readFile(path).then(setContent).catch(() => {}); }}><Text style={styles.editorActionText}>Cancel</Text></Pressable>}</View>
    {editing ? <ScrollView style={{ flex: 1 }} keyboardShouldPersistTaps="handled"><TextInput style={styles.editorInput} value={content} onChangeText={setContent} multiline autoCapitalize="none" autoCorrect={false} textAlignVertical="top" /></ScrollView> : <ScrollView style={{ flex: 1 }}><ScrollView horizontal contentContainerStyle={styles.editorCode}><Text selectable style={styles.editorLineNumbers}>{lines.map((_, index) => String(index + 1)).join('\n')}</Text><SyntaxCode code={content} path={path} /></ScrollView></ScrollView>}
  </KeyboardAvoidingView>;
}
function TerminalScreen({ route, navigation }: any) {
  const state = useRemote(); const root = route.params.root as string;
  const [id, setId] = useState<number | null>(null);
  useEffect(() => {
    let terminal: number | null = null;
    state.openTerminal(root).then(value => { terminal = value; setId(value); }).catch(error => Alert.alert('Terminal', String(error)));
    return () => { if (terminal !== null) state.request('closeTerminal', { id: terminal }).catch(() => {}); };
  }, [root]);
  return <SafeAreaView edges={['left', 'right', 'bottom']} style={styles.page}><HeaderSpacer /><SwipeForward enabled={!!route.params.sessionId} onSwipe={() => navigation.navigate('PullRequest', { sessionId: route.params.sessionId })} onBack={() => navigation.goBack()}><TerminalView id={id} root={root} /></SwipeForward></SafeAreaView>;
}
type ReviewComment = { path: string; line: number; side: 'old' | 'new'; code: string; text: string };
function patchLines(patch: string) {
  let oldLine = 0, newLine = 0;
  const lines: Array<{ old: number | null; next: number | null; text: string; kind: string }> = [];
  for (const text of patch.split('\n')) {
    const hunk = text.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)/);
    if (hunk) { oldLine = Number(hunk[1]); newLine = Number(hunk[2]); lines.push({ old: null, next: null, text, kind: '@' }); continue; }
    if (text.startsWith('+++') || text.startsWith('---') || text.startsWith('diff --git') || text.startsWith('index ')) continue;
    if (text.startsWith('+')) { lines.push({ old: null, next: newLine++, text, kind: '+' }); continue; }
    if (text.startsWith('-')) { lines.push({ old: oldLine++, next: null, text, kind: '-' }); continue; }
    if (text.startsWith(' ')) { lines.push({ old: oldLine++, next: newLine++, text, kind: ' ' }); continue; }
  }
  return lines;
}
function ReviewDiff({ patch, path, onSelect }: { patch: string; path: string; onSelect: (line: ReturnType<typeof patchLines>[number]) => void }) {
  const lines = useMemo(() => patchLines(patch), [patch]);
  const highlighted = useMemo(() => highlightDiffLines(lines, path), [lines, path]);
  return <ScrollView horizontal><View>{lines.map((line, index) => <Pressable key={index} onPress={() => onSelect(line)}>
    <Text style={[styles.mono, styles.diffLine, line.kind === '+' && styles.addedLine, line.kind === '-' && styles.removedLine, line.kind === '@' && styles.hunkLine]}>
      <Text style={line.kind === '+' ? styles.diffAdded : line.kind === '-' ? styles.diffRemoved : styles.diffGutter}>{String(line.old ?? '').padStart(3)} {String(line.next ?? '').padStart(3)} {line.kind === '@' ? '' : line.kind}</Text>
      {line.kind === '@' ? line.text : highlighted[index].map((part, partIndex) => <Text key={partIndex} style={{ color: part.color }}>{part.text}</Text>)}
    </Text>
  </Pressable>)}</View></ScrollView>;
}
function ReviewScreen({ route, navigation }: any) {
  const state = useRemote(); const chat = state.snapshot?.sessions.find(x => x.id === route.params.sessionId);
  const [committed, setCommitted] = useState(false);
  const [files, setFiles] = useState<Array<{ path: string; status: string; additions: number; deletions: number; binary: boolean; patch: string }>>([]);
  const [comments, setComments] = useState<ReviewComment[]>([]);
  const [expandedPaths, setExpandedPaths] = useState<string[]>([]);
  const [selected, setSelected] = useState<Omit<ReviewComment, 'text'> | null>(null);
  const [commentText, setCommentText] = useState('');
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');
  const refresh = () => { if (!chat) return; setError(''); state.request('review', { sessionId: chat.id, committed }).then(response => setFiles(response.review?._0 || [])).catch(reason => setError(String(reason.message || reason))); };
  useEffect(() => { if (chat) refresh(); }, [chat?.id, committed]);
  const decide = (path: string, accept: boolean) => Alert.alert(accept ? 'Accept change?' : 'Discard change?', path, [
    { text: 'Cancel' }, { text: accept ? 'Accept into project' : 'Discard from worktree', style: accept ? 'default' : 'destructive', onPress: () => run(async () => { await state.request('reviewFile', { sessionId: chat!.id, path, committed, accept }); refresh(); }) }
  ]);
  const sendFeedback = () => run(async () => {
    if (!chat || (!comments.length && !message.trim())) return;
    const header = `Review attachment (${committed ? 'committed' : 'uncommitted'})\nCWD: ${chat.worktreePath || ''}`;
    const attachment = comments.map((comment, index) => `\nComment ${index + 1}: ${comment.path}:${comment.side}:${comment.line}\n${comment.text}\n> ${comment.line} ${comment.code}`).join('\n');
    const text = comments.length ? `${message.trim()}\n\n${header}\n${attachment}`.trim() : message.trim();
    await state.request('send', { sessionId: chat.id, text });
    setComments([]); setMessage('');
  });
  const additions = files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = files.reduce((sum, file) => sum + file.deletions, 0);
  return <SwipeForward enabled={!!chat} onSwipe={() => navigation.navigate('Files', { root: chat && activeRoot(chat), sessionId: chat?.id })} onBack={() => navigation.goBack()}><View style={styles.page}>
    <HeaderSpacer />
    <View style={styles.paneToolbar}><NativeSelect label="Review mode" value={committed ? 'Committed' : 'Uncommitted'} align="left" choices={[{ id: 'uncommitted', title: 'Uncommitted', selected: !committed }, { id: 'committed', title: 'Committed', selected: committed }]} onSelect={id => { setCommitted(id === 'committed'); setExpandedPaths([]); }} /><Text style={styles.diffAdded}>+{additions}</Text><Text style={styles.diffRemoved}>−{deletions}</Text><Pressable style={styles.paneIconButton} accessibilityLabel="Refresh review" onPress={refresh}><Icon name="refresh" size={17} /></Pressable><MenuView actions={[{ id: 'expand', title: 'Expand all files' }, { id: 'collapse', title: 'Collapse all files' }]} onPressAction={({ nativeEvent }) => setExpandedPaths(nativeEvent.event === 'expand' ? files.map(file => file.path) : [])}><View style={styles.paneIconButton}><SymbolView name={{ ios: 'ellipsis', android: 'more_horiz' }} size={19} tintColor={muted} /></View></MenuView></View>
    <KeyboardAwareScrollView style={{ flex: 1 }} contentContainerStyle={styles.paneContent}>
      {error ? <View style={styles.paneEmpty}><Icon name="failed" size={22} color="#EF6461" /><Text style={styles.paneEmptyTitle}>Couldn't load changes</Text><Text style={styles.empty}>{error}</Text><Button title="Try again" secondary onPress={refresh} /></View> : null}
      {files.map(file => { const expanded = expandedPaths.includes(file.path); return <View key={file.path} style={styles.reviewFile}>
        <Pressable style={styles.reviewFileHeader} onPress={() => setExpandedPaths(expanded ? expandedPaths.filter(path => path !== file.path) : [...expandedPaths, file.path])}><Icon name="chevron" size={11} color={tertiary} /><FileIcon path={file.path} size={17} /><View style={{ flex: 1, minWidth: 0 }}><Text numberOfLines={1} style={styles.fileTreeTitle}>{file.path.split('/').at(-1)}</Text>{file.path.includes('/') && <Text numberOfLines={1} style={styles.fileTreeSubtitle}>{file.path.slice(0, file.path.lastIndexOf('/'))}</Text>}</View><Text style={styles.diffAdded}>+{file.additions}</Text><Text style={styles.diffRemoved}>−{file.deletions}</Text></Pressable>
        {expanded && <View style={styles.reviewFileBody}>{file.binary ? <Text style={styles.mono}>Binary file</Text> : <ReviewDiff patch={file.patch} path={file.path} onSelect={line => { if (line.old !== null || line.next !== null) { setSelected({ path: file.path, line: line.next ?? line.old!, side: line.next !== null ? 'new' : 'old', code: line.text.slice(1) }); setCommentText(''); } }} />}<View style={styles.reviewFileActions}><ReviewFileButton title="Apply to project" onPress={() => decide(file.path, true)} />{!committed && <ReviewFileButton title="Discard changes" destructive onPress={() => decide(file.path, false)} />}</View></View>}
      </View>; })}
      {!files.length && !error && <View style={styles.paneEmpty}><Icon name="check" size={23} color={tertiary} /><Text style={styles.paneEmptyTitle}>No changes to display</Text><Text style={styles.empty}>{committed ? 'This branch has no committed changes.' : 'Nothing uncommitted in this worktree.'}</Text></View>}
      {selected && <PaneSection title={`Comment on ${selected.path}:${selected.line}`}><Text style={styles.mono}>{selected.code}</Text><TextInput style={[styles.input, styles.multiline]} multiline value={commentText} onChangeText={setCommentText} placeholder="Review comment" placeholderTextColor={muted} /><View style={styles.reviewActions}><Button title="Add comment" onPress={() => { if (commentText.trim()) setComments([...comments, { ...selected, text: commentText.trim() }]); setSelected(null); setCommentText(''); }} /><Button title="Cancel" secondary onPress={() => setSelected(null)} /></View></PaneSection>}
      {comments.length > 0 && <PaneSection title="Draft comments" detail={String(comments.length)}>{comments.map((comment, index) => <Row key={index} title={`${comment.path}:${comment.line}`} subtitle={comment.text} onPress={() => setComments(comments.filter((_, i) => i !== index))} trailing="Remove" />)}</PaneSection>}
      {(files.length > 0 || comments.length > 0) && <PaneSection title="Send review to agent"><TextInput style={[styles.input, styles.multiline]} multiline value={message} onChangeText={setMessage} placeholder="Optional summary" placeholderTextColor={muted} /><Button title="Send review" onPress={sendFeedback} /></PaneSection>}
    </KeyboardAwareScrollView>
  </View></SwipeForward>;
}
function PullRequestScreen({ route, navigation }: any) {
  const state = useRemote(); const sessionId = route.params.sessionId as string;
  const blurTarget = useRef<View>(null);
  const headerHeight = useHeaderHeight();
  const chat = state.snapshot?.sessions.find(x => x.id === sessionId);
  const pr = state.snapshot?.pullRequests?.[sessionId];
  const [title, setTitle] = useState(chat?.name || ''); const [body, setBody] = useState('');
  const [base, setBase] = useState(chat?.baseRef || ''); const [draft, setDraft] = useState(false);
  const [message, setMessage] = useState('');
  const [publishOpen, setPublishOpen] = useState(false);
  const [working, setWorking] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const request = async (name: string, label: string, args: Record<string, unknown> = {}) => {
    if (working) return;
    setWorking(label);
    setActionError(null);
    try {
      await state.request(name, { sessionId, ...args });
      await state.refresh();
      if (name === 'pushChanges') { setPublishOpen(false); setMessage(''); }
    } catch (error) {
      setActionError(String(error instanceof Error ? error.message : error));
    } finally {
      setWorking(null);
    }
  };
  useEffect(() => {
    navigation.setOptions({
      headerTransparent: true,
      headerStyle: { backgroundColor: 'transparent' },
      headerBackground: () => <ProgressiveBlur edge="top" blurTarget={blurTarget} />,
      headerRight: () => pr ? (working ? <View accessibilityLabel="GitHub actions unavailable" style={[styles.prNavigationIcon, styles.prButtonDisabled]}><SymbolView name={{ ios: 'ellipsis', android: 'more_horiz' }} size={19} tintColor={muted} /></View> :
        <MenuView title="GitHub actions" actions={[
          ...(pr.url ? [{ id: 'open', title: 'Open on GitHub', image: Platform.OS === 'ios' ? 'arrow.up.forward.square' : undefined }] : []),
          ...(pr.state.toLowerCase() === 'open' ? [
            ...(pr.isDraft ? [{ id: 'ready', title: 'Ready for review' }] : [{ id: 'merge', title: 'Merge pull request', attributes: { disabled: !!pr.hasConflicts }, subactions: [
              { id: 'squash', title: 'Squash and merge' }, { id: 'mergeCommit', title: 'Create a merge commit' }, { id: 'rebase', title: 'Rebase and merge' },
            ] }]),
            { id: 'close', title: 'Close pull request', attributes: { destructive: true } },
          ] : []),
        ]} onPressAction={({ nativeEvent }) => {
          const action = nativeEvent.event;
          if (action === 'open' && pr.url) Linking.openURL(pr.url).catch(() => {});
          else if (action === 'ready') request('markPullRequestReady', 'Marking ready…');
          else if (action === 'close') Alert.alert('Close pull request?', pr.title, [{ text: 'Cancel' }, { text: 'Close', style: 'destructive', onPress: () => request('closePullRequest', 'Closing…') }]);
          else if (['squash', 'mergeCommit', 'rebase'].includes(action)) Alert.alert('Merge pull request?', `Use ${action === 'mergeCommit' ? 'merge' : action} for #${pr.number}?`, [{ text: 'Cancel' }, { text: 'Merge', onPress: () => request('mergePullRequest', 'Merging…', { method: action === 'mergeCommit' ? 'merge' : action }) }]);
        }}><View accessibilityRole="button" accessibilityLabel="GitHub actions" style={styles.prNavigationIcon}><SymbolView name={{ ios: 'ellipsis', android: 'more_horiz' }} size={19} tintColor={muted} /></View></MenuView>) : null,
    });
  }, [navigation, pr, working]);
  const checkSummary = pr?.checks?.length ? [
    `${pr.checks.filter(x => x.outcome === 'failed').length} failed`,
    `${pr.checks.filter(x => x.outcome === 'pending').length} running`,
    `${pr.checks.filter(x => x.outcome === 'passed').length} passed`,
  ].filter(x => !x.startsWith('0 ')).join(' · ') : undefined;
  return <View style={styles.page}>
    <BlurTargetView ref={blurTarget} style={{ flex: 1 }}>
    <KeyboardAwareScrollView style={{ flex: 1 }} contentContainerStyle={[styles.paneContent, { paddingTop: headerHeight }]}>
    {actionError && <View style={styles.prActionError}><Text style={styles.error}>{actionError}</Text></View>}
    {pr ? <>
      <View style={styles.prHeader}>
        <View style={styles.prStatusLine}><PullRequestIcon pr={pr} size={15} /><Text style={[styles.prState, { color: pr.state.toLowerCase() === 'merged' ? '#B79CF0' : pr.state.toLowerCase() === 'closed' ? '#F08A84' : pr.isDraft ? '#A0A8B2' : '#6BC98A' }]}>{pr.isDraft ? 'Draft' : pr.state}</Text><Text style={styles.prNumber}>#{pr.number}</Text></View>
        <Text style={styles.prTitle}>{pr.title}</Text>
        <View style={styles.prMetadata}>{pr.author && <Text style={styles.prAuthor}>{pr.author}</Text>}<Text style={styles.prBranch} numberOfLines={1}>{pr.head || chat?.branch || 'Branch'} → {pr.base || chat?.baseRef || 'base'}</Text>{pr.additions != null && <Text style={styles.diffAdded}>+{pr.additions}</Text>}{pr.deletions != null && <Text style={styles.diffRemoved}>−{pr.deletions}</Text>}</View>
        {pr.reviewDecision && <Text style={styles.prStanding}>{({ APPROVED: 'Approved', CHANGES_REQUESTED: 'Changes requested', REVIEW_REQUIRED: 'Review required' } as Record<string, string>)[pr.reviewDecision] || pr.reviewDecision}</Text>}
        {pr.standing && <Text style={[styles.prStanding, pr.checks?.some(check => check.outcome === 'failed') && { color: '#EF6461' }]}>{pr.standing}</Text>}
      </View>
      {!!pr.checks?.length && <PaneSection title="Checks" detail={checkSummary}>{[...pr.checks].sort((a, b) => ({ failed: 0, pending: 1, passed: 2, skipped: 3 }[a.outcome] ?? 4) - ({ failed: 0, pending: 1, passed: 2, skipped: 3 }[b.outcome] ?? 4)).map(check => <Pressable key={`${check.workflow || ''}/${check.name}`} style={styles.prCheckRow} onPress={() => check.url && Linking.openURL(check.url).catch(() => {})}><Icon name={check.outcome === 'passed' ? 'check' : check.outcome === 'failed' ? 'failed' : check.outcome === 'pending' ? 'pending' : 'skipped'} size={14} color={check.outcome === 'failed' ? '#EF6461' : check.outcome === 'passed' ? '#4CC38A' : muted} /><View style={{ flex: 1 }}><Text style={styles.fileTreeTitle}>{check.name}</Text>{check.workflow && <Text style={styles.fileTreeSubtitle}>{check.workflow}</Text>}</View>{check.url && <SymbolView name={{ ios: 'arrow.up.right', android: 'open_in_new' }} size={12} tintColor={tertiary} />}</Pressable>)}</PaneSection>}
      {!!pr.body && <PaneSection title="Description"><Text style={styles.prBody}>{pr.body}</Text></PaneSection>}
      {!!((pr.reviews?.length || 0) + (pr.comments?.length || 0) + (pr.threads?.length || 0)) && <PaneSection title="Reviews" detail={pr.reviewDecision ? ({ APPROVED: 'Approved', CHANGES_REQUESTED: 'Changes requested', REVIEW_REQUIRED: 'Review required' } as Record<string, string>)[pr.reviewDecision] : undefined}>
        {(pr.reviews || []).map((review, index) => <View key={`review-${index}`} style={styles.prConversation}><Text style={styles.prConversationAuthor}>{review.author} <Text style={styles.prConversationMeta}>{review.verdict.toLowerCase().replaceAll('_', ' ')}</Text></Text>{review.body ? <Text style={styles.prBody}>{review.body}</Text> : null}</View>)}
        {(pr.threads || []).map(thread => <View key={thread.id} style={styles.prConversation}><Text style={styles.prConversationAuthor}>{thread.path}{thread.line ? `:${thread.line}` : ''} <Text style={styles.prConversationMeta}>{thread.isResolved ? 'Resolved' : thread.isOutdated ? 'Outdated' : 'Open thread'}</Text></Text>{thread.comments.map((comment, index) => <Text key={`${thread.id}-${index}`} style={styles.prBody}><Text style={styles.prConversationAuthor}>{comment.author}: </Text>{comment.body}</Text>)}</View>)}
        {(pr.comments || []).filter(comment => !comment.isBot).map((comment, index) => <View key={`comment-${index}`} style={styles.prConversation}><Text style={styles.prConversationAuthor}>{comment.author}</Text><Text style={styles.prBody}>{comment.body}</Text></View>)}
        {(pr.comments || []).filter(comment => comment.isBot).length > 0 && <Text style={styles.prConversationMeta}>{(pr.comments || []).filter(comment => comment.isBot).length} automated comments</Text>}
      </PaneSection>}
      {pr.state.toLowerCase() === 'open' && <PaneSection title="Publish changes">
        <PRButton title="Commit and push" disabled={!!working} onPress={() => setPublishOpen(!publishOpen)} />
        {pr.hasConflicts && !pr.isDraft && <Text style={styles.prHelp}>Resolve conflicts with {pr.base || 'the base branch'} before merging.</Text>}
        {publishOpen && <View style={styles.prPublishForm}><TextInput style={styles.input} value={message} onChangeText={setMessage} placeholder="Commit message" placeholderTextColor={muted} editable={!working} /><PRButton title="Commit and push changes" kind="primary" disabled={!!working || !message.trim()} loading={working === 'Pushing…'} onPress={() => request('pushChanges', 'Pushing…', { message: message.trim() })} /></View>}
      </PaneSection>}
    </> : <PaneSection title="Create pull request">
      <Text style={styles.prHelp}>Open a pull request for this chat’s branch.</Text>
      <Text style={styles.label}>Title</Text><TextInput style={styles.input} value={title} onChangeText={setTitle} editable={!working} placeholder="Pull request title" placeholderTextColor={tertiary} />
      <Text style={styles.label}>Description</Text><TextInput style={[styles.input, styles.multiline]} value={body} onChangeText={setBody} editable={!working} multiline placeholder="What changed, and why (optional)" placeholderTextColor={tertiary} />
      <Text style={styles.label}>Base branch</Text><TextInput style={styles.input} value={base} onChangeText={setBase} editable={!working} autoCapitalize="none" placeholder="Default branch" placeholderTextColor={tertiary} />
      <View style={styles.prCreateFooter}>
        <Pressable accessibilityRole="checkbox" accessibilityState={{ checked: draft, disabled: !!working }} disabled={!!working} onPress={() => setDraft(!draft)} style={styles.prDraftToggle}><View style={[styles.prDraftBox, draft && styles.prDraftBoxChecked]}>{draft && <Icon name="check" size={12} color={bg} />}</View><Text style={styles.prButtonText}>Draft</Text></Pressable>
        <PRButton title="Create pull request" kind="primary" disabled={!!working || !title.trim()} loading={working === 'Creating…'} onPress={() => request('createPullRequest', 'Creating…', { title: title.trim(), body, base: base.trim() || null, draft, commitFirst: true })} />
      </View>
    </PaneSection>}
    </KeyboardAwareScrollView>
    </BlurTargetView>
  </View>;
}
function AutomationsScreen({ navigation }: any) {
  const state = useRemote(); const automations = state.snapshot?.automations || [];
  return <HeaderScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Automations</Text><Text style={styles.lead}>Scheduled on {state.active?.peer.name || 'a connected Mac'}.</Text><Button title="New automation" onPress={() => navigation.navigate('Automation', {})} />
    {automations.map(a => <Row key={a.id} title={a.name} subtitle={`${a.enabled ? 'Enabled' : 'Paused'} · ${a.providerId} · ${a.nextRunAt ? displayDate(a.nextRunAt) : 'Manual'}`} onPress={() => navigation.navigate('Automation', { id: a.id })} />)}{!automations.length && <Empty text="No automations on this Mac." />}
  </HeaderScrollView>;
}
function AutomationScreen({ route, navigation }: any) {
  const state = useRemote(); const existing = state.snapshot?.automations?.find(x => x.id === route.params?.id);
  const [name, setName] = useState(existing?.name || ''); const [prompt, setPrompt] = useState(existing?.prompt || '');
  const [triggers, setTriggers] = useState<AutomationTrigger[]>(existing?.triggers || []);
  const [provider, setProvider] = useState(existing?.providerId || state.snapshot?.providers[0] || 'claude');
  const [projectId, setProjectId] = useState(existing?.projectId || null as string | null);
  const [enabled, setEnabled] = useState(existing?.enabled ?? true);
  const [workspaceMode, setWorkspaceMode] = useState(existing?.workspaceMode || 'new_worktree');
  const [pinnedSessionId, setPinnedSessionId] = useState(existing?.pinnedSessionId || null as string | null);
  const [continueAgentSession, setContinueAgentSession] = useState(existing?.continueAgentSession || false);
  const [catchUp, setCatchUp] = useState(existing?.catchUp || false);
  const [policy, setPolicy] = useState(existing?.permissionPolicy || 'auto-edits');
  const [modelName, setModelName] = useState(existing?.model || '');
  const [effort, setEffort] = useState(existing?.effort || '');
  const [runs, setRuns] = useState<any[]>([]);
  useEffect(() => { if (existing) state.request('automationRuns', { id: existing.id }).then(x => setRuns(x.automationRuns?._0 || [])).catch(() => {}); }, [existing?.id]);
  const save = async () => {
    if (!name.trim() || !prompt.trim()) throw Error('Name and prompt are required.');
    const now = swiftDate();
    const automation: Automation = {
      id: existing?.id || uuid(), name, prompt, providerId: provider, projectId,
      triggers: triggers.filter(x => x.rrule.trim()).map(x => ({ ...x, rrule: x.rrule.trim() })),
      workspaceMode, pinnedSessionId: workspaceMode === 'pinned' ? pinnedSessionId : null,
      continueAgentSession, permissionPolicy: policy, catchUp,
      enabled, nextRunAt: existing?.nextRunAt || null, createdAt: existing?.createdAt || now, updatedAt: now, model: modelName || null, effort: effort || null
    };
    await state.request('saveAutomation', { _0: automation }); navigation.goBack();
  };
  return <HeaderScrollView keyboardAware style={styles.page} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled"><Text style={styles.label}>Name</Text><TextInput style={styles.input} value={name} onChangeText={setName} placeholder="Automation name" placeholderTextColor={muted} />
    <Text style={styles.label}>Prompt</Text><TextInput style={[styles.input, styles.multiline]} value={prompt} onChangeText={setPrompt} multiline placeholder="What should run?" placeholderTextColor={muted} />
    <Text style={styles.label}>Agent</Text><View style={styles.choices}>{state.snapshot?.providers.map(x => <Button key={x} title={x} secondary={provider !== x} onPress={() => setProvider(x)} />)}</View>
    <Text style={styles.label}>Project</Text><View style={styles.choices}><Button title="No project" secondary={projectId !== null} onPress={() => setProjectId(null)} />{state.snapshot?.projects.map(x => <Button key={x.id} title={x.name} secondary={projectId !== x.id} onPress={() => setProjectId(x.id)} />)}</View>
    <Text style={styles.label}>Workspace</Text><View style={styles.choices}><Button title="New worktree each run" secondary={workspaceMode !== 'new_worktree'} onPress={() => setWorkspaceMode('new_worktree')} /><Button title="Continue one chat" secondary={workspaceMode !== 'pinned'} onPress={() => setWorkspaceMode('pinned')} /></View>
    {workspaceMode === 'pinned' && <Section title="Chat to continue">{(state.snapshot?.sessions || []).filter(x => x.projectId === projectId).map(chat => <Button key={chat.id} title={chat.name} secondary={pinnedSessionId !== chat.id} onPress={() => setPinnedSessionId(chat.id)} />)}<Text style={styles.hint}>Choose a chat, or leave this empty to create one on the first run.</Text></Section>}
    {workspaceMode === 'pinned' && <Button title={continueAgentSession ? 'Continue agent session: on' : 'Continue agent session: off'} secondary={!continueAgentSession} onPress={() => setContinueAgentSession(!continueAgentSession)} />}
    <Text style={styles.label}>Permissions</Text><View style={styles.choices}>{(['ask', 'auto-edits', 'bypass'] as const).map(value => <Button key={value} title={value} secondary={policy !== value} onPress={() => setPolicy(value)} />)}</View>
    <Text style={styles.label}>Model (optional)</Text><TextInput style={styles.input} value={modelName} onChangeText={setModelName} autoCapitalize="none" />
    <Text style={styles.label}>Reasoning effort (optional)</Text><TextInput style={styles.input} value={effort} onChangeText={setEffort} autoCapitalize="none" />
    <Text style={styles.label}>Schedules (RRULE)</Text>{triggers.map((trigger, index) => <Section key={trigger.id} title={`Schedule ${index + 1}`}><TextInput style={styles.input} value={trigger.rrule} onChangeText={text => setTriggers(triggers.map(x => x.id === trigger.id ? { ...x, rrule: text } : x))} autoCapitalize="characters" placeholder="FREQ=DAILY;BYHOUR=9;BYMINUTE=0" placeholderTextColor={muted} /><TextInput style={styles.input} value={trigger.timezone} onChangeText={text => setTriggers(triggers.map(x => x.id === trigger.id ? { ...x, timezone: text } : x))} autoCapitalize="none" placeholder="IANA timezone" placeholderTextColor={muted} /><Button title="Remove schedule" secondary onPress={() => setTriggers(triggers.filter(x => x.id !== trigger.id))} /></Section>)}<Button title="Add schedule" secondary onPress={() => setTriggers([...triggers, { id: uuid(), rrule: 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, dtstart: swiftDate() }])} />
    <Button title={catchUp ? 'Catch up on launch: on' : 'Catch up on launch: off'} secondary={!catchUp} onPress={() => setCatchUp(!catchUp)} />
    <View style={styles.actions}><Button title={enabled ? 'Enabled' : 'Paused'} secondary={!enabled} onPress={() => setEnabled(!enabled)} /><Button title="Save" onPress={() => run(save)} /></View>
    {existing && <Section title="Actions"><Button title="Run now" secondary onPress={() => run(() => state.request('runAutomation', { id: existing.id }))} /><Button title="Delete" danger onPress={() => Alert.alert('Delete automation?', existing.name, [{ text: 'Cancel' }, { text: 'Delete', style: 'destructive', onPress: () => run(async () => { await state.request('deleteAutomation', { id: existing.id }); navigation.goBack(); }) }])} /></Section>}
    {runs.length ? <Section title="Recent runs">{runs.map(x => <Text style={styles.body} key={x.id}>{displayDate(x.firedAt)} · {x.status}{x.error ? ` · ${x.error}` : ''}</Text>)}</Section> : null}
  </HeaderScrollView>;
}
export default function App() {
  const [fontsLoaded] = useFonts({ Inter: require('../assets/fonts/InterVariable.ttf'), JetBrainsMono: require('../assets/fonts/JetBrainsMono-Regular.ttf'), JetBrainsMonoMedium: require('../assets/fonts/JetBrainsMono-Medium.ttf') });
  useEffect(() => {
    remote.load();
    const appState = AppState.addEventListener('change', value => {
      if (value === 'active') remote.resume().catch(() => {});
    });
    return () => appState.remove();
  }, []);
  if (!fontsLoaded) return null;
  return <SafeAreaProvider><StatusBar style="light" /><NavigationContainer theme={{ dark: true, colors: { primary: accent, background: bg, card: panel, text: ink, border, notification: accent }, fonts: { regular: { fontFamily: 'Inter', fontWeight: '400' }, medium: { fontFamily: 'Inter', fontWeight: '500' }, bold: { fontFamily: 'Inter', fontWeight: '700' }, heavy: { fontFamily: 'Inter', fontWeight: '900' } } }}>
      <Stack.Navigator initialRouteName="Sidebar" screenOptions={({ navigation }: any) => ({ headerTransparent: true, headerStyle: { backgroundColor: 'transparent' }, headerBackground: () => <ProgressiveBlur edge="top" />, headerTitleStyle: { fontFamily: 'Inter', fontSize: 15 }, headerTintColor: ink, contentStyle: { backgroundColor: bg }, headerShadowVisible: false, headerBackVisible: false, headerLeft: () => <ScreenNavigation navigation={navigation} />, scrollEdgeEffects: Platform.OS === 'ios' ? { top: 'soft' } : undefined, animation: 'slide_from_right', gestureEnabled: true, fullScreenGestureEnabled: true, animationMatchesGesture: true })}>
        <Stack.Screen name="Sidebar" component={SidebarScreen} options={{ headerShown: true, title: '', headerLeft: () => null, headerBackground: () => <ProgressiveBlur edge="top" surfaceColor={sidebar} /> }} />
        <Stack.Screen name="Settings" component={SettingsScreen} options={{ title: 'Settings' }} />
        <Stack.Screen name="Projects" component={ProjectsScreen} />
        <Stack.Screen name="Chats" component={ChatsScreen} />
        <Stack.Screen name="Project" component={ProjectScreen} />
        <Stack.Screen name="NewChat" component={NewChatScreen} options={{ title: 'New chat' }} />
        <Stack.Screen name="Chat" component={ChatWorkspace} options={{ title: '', headerShown: true }} />
        <Stack.Screen name="Worktrees" component={WorktreesScreen} />
        <Stack.Screen name="Files" component={FilesScreen} />
        <Stack.Screen name="File" component={FileScreen} />
        <Stack.Screen name="Terminal" component={TerminalScreen} />
        <Stack.Screen name="Review" component={ReviewScreen} />
        <Stack.Screen name="PullRequests" component={PullRequestsScreen} options={{ title: 'Pull requests' }} />
        <Stack.Screen name="PullRequest" component={PullRequestScreen} options={{ title: 'Pull request' }} />
        <Stack.Screen name="Automations" component={AutomationsScreen} />
        <Stack.Screen name="Automation" component={AutomationScreen} />
      </Stack.Navigator>
    </NavigationContainer></SafeAreaProvider>;
}
const styles = StyleSheet.create({
  launcherContent: { paddingHorizontal: 18, paddingTop: 30, paddingBottom: 48, alignItems: 'center' },
  launcherIntro: { width: '100%', maxWidth: 680, alignItems: 'center', gap: 10, marginBottom: 32 },
  launcherTitle: { color: ink, fontFamily: 'Inter', fontSize: 26, fontWeight: '600', textAlign: 'center' },
  launcherDescription: { color: muted, fontFamily: 'Inter', fontSize: 13.5, lineHeight: 20, textAlign: 'center', maxWidth: 460 },
  launcherBox: { width: '100%', maxWidth: 680, backgroundColor: panel, borderWidth: 1, borderColor: '#424249', borderRadius: 10, overflow: 'hidden' },
  launcherPrompt: { color: ink, fontFamily: 'Inter', fontSize: 15, lineHeight: 22, minHeight: 138, maxHeight: 260, paddingHorizontal: 18, paddingTop: 17, paddingBottom: 12 },
  launcherAttachments: { flexDirection: 'row', flexWrap: 'wrap', gap: 5, paddingHorizontal: 12, paddingBottom: 8 },
  launcherAttachment: { maxWidth: '100%', paddingHorizontal: 9, paddingVertical: 6, borderRadius: 6, backgroundColor: raised },
  launcherControls: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', columnGap: 3, rowGap: 2, paddingHorizontal: 8 },
  launcherPicker: { height: 32, flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 7, borderRadius: 6 },
  launcherPickerText: { color: muted, fontFamily: 'Inter', fontSize: 12.5, fontWeight: '500', maxWidth: 150 },
  launcherBase: { height: 32, flexDirection: 'row', alignItems: 'center', paddingHorizontal: 7, gap: 5 },
  launcherBaseLabel: { color: tertiary, fontFamily: 'Inter', fontSize: 12.5 },
  launcherBaseInput: { minWidth: 85, maxWidth: 130, color: muted, fontFamily: 'JetBrainsMono', fontSize: 12.5, padding: 0 },
  launcherCustomModel: { color: ink, fontFamily: 'JetBrainsMono', fontSize: 13, marginHorizontal: 15, marginTop: 7, paddingHorizontal: 9, minHeight: 38, borderRadius: 6, backgroundColor: inset },
  launcherWarning: { color: muted, fontFamily: 'Inter', fontSize: 12, lineHeight: 18, paddingHorizontal: 17, paddingTop: 8 },
  launcherFooter: { flexDirection: 'row', justifyContent: 'flex-end', paddingHorizontal: 12, paddingTop: 2, paddingBottom: 12 },
  launcherStart: { minHeight: 36, flexDirection: 'row', alignItems: 'center', gap: 7, paddingHorizontal: 13, borderRadius: 7, backgroundColor: ink },
  launcherStartDisabled: { opacity: 0.4 },
  launcherStartText: { color: bg, fontFamily: 'Inter', fontSize: 13, fontWeight: '600' },
  launcherRecent: { width: '100%', maxWidth: 680, marginTop: 35 },
  launcherRecentLabel: { color: tertiary, fontFamily: 'Inter', fontSize: 11, fontWeight: '600', textTransform: 'uppercase', letterSpacing: 0.6, marginBottom: 8 },
  launcherRecentRow: { minHeight: 38, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 8 },
  launcherRecentName: { flex: 1, color: ink, fontFamily: 'Inter', fontSize: 14 },
  launcherRecentMeta: { color: tertiary, fontFamily: 'Inter', fontSize: 11, maxWidth: 110 },
  headerAction: { width: 42, height: 44, alignItems: 'center', justifyContent: 'center' },
  page: { flex: 1, backgroundColor: bg }, content: { padding: 18, gap: 16, paddingBottom: 32 }, title: { color: ink, fontFamily: 'Inter', fontSize: 25, fontWeight: '600' }, lead: { color: muted, fontFamily: 'Inter', fontSize: 14, lineHeight: 21 }, section: { backgroundColor: panel, borderRadius: 8, padding: 14, gap: 9, borderWidth: StyleSheet.hairlineWidth, borderColor: border }, sectionTitle: { color: muted, fontFamily: 'Inter', fontSize: 13.5, fontWeight: '600' }, label: { color: muted, fontFamily: 'Inter', fontSize: 12, fontWeight: '600', marginTop: 8 }, value: { color: ink, fontFamily: 'Inter', fontSize: 15 }, row: { minHeight: 56, paddingVertical: 11, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border, flexDirection: 'row', alignItems: 'center', gap: 10 }, rowTitle: { color: ink, fontFamily: 'Inter', fontSize: 15.5, fontWeight: '500' }, subtitle: { color: muted, fontFamily: 'Inter', fontSize: 12.5, marginTop: 4 }, trailing: { color: tertiary, fontFamily: 'Inter', fontSize: 11 }, button: { backgroundColor: accent, borderRadius: 8, paddingHorizontal: 14, paddingVertical: 11, alignSelf: 'flex-start', marginRight: 5, marginBottom: 5 }, buttonText: { color: bg, fontFamily: 'Inter', fontSize: 14, fontWeight: '600' }, secondary: { backgroundColor: inset }, danger: { backgroundColor: '#9B3F43' }, input: { backgroundColor: inset, color: ink, borderRadius: 7, borderWidth: StyleSheet.hairlineWidth, borderColor: border, paddingHorizontal: 12, paddingVertical: 10, fontFamily: 'Inter', fontSize: 15, minHeight: 48 }, multiline: { minHeight: 120, textAlignVertical: 'top' }, actions: { flexDirection: 'row', flexWrap: 'wrap', marginVertical: 5 }, choices: { flexDirection: 'row', flexWrap: 'wrap' }, empty: { color: muted, fontFamily: 'Inter', fontSize: 14, lineHeight: 21 }, error: { color: '#EF6461' }, callout: { backgroundColor: raised, borderRadius: 8, borderColor: border, borderWidth: StyleSheet.hairlineWidth, padding: 15 }, code: { color: ink, fontFamily: 'JetBrainsMonoMedium', fontSize: 32, letterSpacing: 3 }, bubble: { backgroundColor: raised, padding: 13, borderRadius: 8, marginBottom: 8 }, bubbleLabel: { color: muted, fontFamily: 'Inter', fontSize: 11, marginBottom: 5 }, body: { color: ink, fontFamily: 'Inter', fontSize: 14.5, lineHeight: 22 }, mono: { color: ink, fontSize: 11, fontFamily: 'JetBrainsMono', lineHeight: 17 }, hint: { color: tertiary, fontFamily: 'Inter', fontSize: 11 }, composer: { backgroundColor: panel, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border, padding: 10, flexDirection: 'row', alignItems: 'flex-end' }, codeScroll: { padding: 16 }, codeText: { color: ink, fontFamily: 'JetBrainsMono', fontSize: 11, textAlignVertical: 'top', minHeight: 500 },
  rail: { flex: 1, backgroundColor: sidebar }, railContent: { paddingTop: 10, paddingBottom: 24 }, railAction: { height: 50, paddingHorizontal: 18, flexDirection: 'row', alignItems: 'center', gap: 12 }, railActionTitle: { color: ink, fontFamily: 'Inter', fontSize: 15.5, flex: 1 }, railDetail: { color: tertiary, fontFamily: 'Inter', fontSize: 12 }, railHost: { marginTop: 18, marginHorizontal: 14, height: 48, paddingHorizontal: 5, flexDirection: 'row', alignItems: 'center', gap: 8, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border }, railHostTitle: { color: muted, fontFamily: 'Inter', fontSize: 12, fontWeight: '600', flex: 1 }, railGroup: { paddingTop: 12 }, railGroupHeader: { paddingHorizontal: 18, height: 38, flexDirection: 'row', alignItems: 'center', gap: 6 }, railGroupTitle: { color: muted, fontFamily: 'Inter', fontSize: 14, fontWeight: '600', flex: 1 }, railChat: { height: 44, paddingLeft: 24, paddingRight: 18, flexDirection: 'row', alignItems: 'center', gap: 9 }, railChatSelected: { backgroundColor: raised }, railChatTitle: { color: ink, fontFamily: 'Inter', fontSize: 14.5, flex: 1 }, statusDiamond: { width: 6, height: 6, backgroundColor: tertiary, transform: [{ rotate: '45deg' }] }, statusRunning: { backgroundColor: '#4CC38A' }, railEmpty: { color: muted, fontFamily: 'Inter', fontSize: 12, lineHeight: 18, margin: 18 }, railFooter: { minHeight: 60, paddingHorizontal: 18, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border, flexDirection: 'row', alignItems: 'center', gap: 10 }, railFooterTitle: { color: ink, fontFamily: 'Inter', fontSize: 15, flex: 1 }, connectionDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: '#4CC38A' },
  paneToolbar: { height: 45, paddingHorizontal: 10, flexDirection: 'row', alignItems: 'center', gap: 8, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border, backgroundColor: bg },
  paneIconButton: { width: 42, height: 42, alignItems: 'center', justifyContent: 'center' },
  paneContent: { paddingBottom: 30 },
  paneSection: { paddingHorizontal: 15, paddingTop: 18, paddingBottom: 12, gap: 9, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  paneSectionHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 2 },
  paneSectionTitle: { flex: 1, color: muted, fontFamily: 'Inter', fontWeight: '600', fontSize: 13.5 },
  paneSectionDetail: { color: tertiary, fontFamily: 'Inter', fontSize: 11 },
  paneEmpty: { flex: 1, alignItems: 'center', justifyContent: 'center', minHeight: 220, padding: 25, gap: 10 },
  paneEmptyTitle: { color: ink, fontFamily: 'Inter', fontSize: 15, fontWeight: '600' },
  paneMenuButton: { height: 42, paddingHorizontal: 10, backgroundColor: inset, borderRadius: 6, flexDirection: 'row', alignItems: 'center', gap: 8, alignSelf: 'flex-start' },
  paneMenuLabel: { color: ink, fontFamily: 'Inter', fontSize: 13.5, fontWeight: '500' },
  filesFilterSection: { paddingHorizontal: 16, paddingTop: 14, paddingBottom: 13, gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  filesFilterHeading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  filesFilterTitle: { color: tertiary, fontFamily: 'Inter', fontSize: 10, fontWeight: '700', letterSpacing: 0.8 },
  filesFilterCount: { color: tertiary, fontFamily: 'Inter', fontSize: 11 },
  filesFilterRow: { flexDirection: 'row', alignItems: 'center', gap: 9 },
  fileFilter: { flex: 1, height: 44, backgroundColor: panel, borderRadius: 9, borderWidth: StyleSheet.hairlineWidth, borderColor: '#45454D', flexDirection: 'row', alignItems: 'center', gap: 9, paddingHorizontal: 12 },
  fileFilterInput: { flex: 1, minWidth: 0, color: ink, fontFamily: 'Inter', fontSize: 14, paddingVertical: 0 },
  fileFilterClear: { width: 28, height: 28, alignItems: 'center', justifyContent: 'center' },
  fileRefreshButton: { width: 44, height: 44, backgroundColor: panel, borderRadius: 9, borderWidth: StyleSheet.hairlineWidth, borderColor: '#45454D', alignItems: 'center', justifyContent: 'center' },
  breadcrumb: { minHeight: 34, marginHorizontal: 16, marginTop: 10, marginBottom: 4, paddingHorizontal: 10, backgroundColor: panel, borderRadius: 7, flexDirection: 'row', alignItems: 'center', gap: 7 },
  breadcrumbText: { flex: 1, color: muted, fontFamily: 'JetBrainsMono', fontSize: 11 },
  fileList: { paddingTop: 4, paddingBottom: 24 },
  fileTreeRow: { minHeight: 50, paddingHorizontal: 16, paddingVertical: 7, flexDirection: 'row', alignItems: 'center', gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  fileTreeTitle: { color: ink, fontFamily: 'Inter', fontSize: 14.5, fontWeight: '500' },
  fileTreeSubtitle: { color: tertiary, fontFamily: 'Inter', fontSize: 10, marginTop: 2 },
  diffAdded: { color: '#4CC38A', fontFamily: 'JetBrainsMono', fontSize: 11 },
  diffRemoved: { color: '#EF6461', fontFamily: 'JetBrainsMono', fontSize: 11 },
  reviewFile: { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  reviewFileHeader: { minHeight: 60, paddingHorizontal: 13, paddingVertical: 7, flexDirection: 'row', alignItems: 'center', gap: 8 },
  reviewFileBody: { backgroundColor: panel, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border, paddingTop: 4 },
  diffLine: { minHeight: 19, paddingHorizontal: 12, lineHeight: 19 },
  diffGutter: { color: tertiary },
  hunkLine: { color: '#91B8F6', backgroundColor: 'rgba(145,184,246,0.06)' },
  addedLine: { color: '#8FCBAB', backgroundColor: 'rgba(76,195,138,0.08)' },
  removedLine: { color: '#E9A09D', backgroundColor: 'rgba(239,100,97,0.08)' },
  reviewFileActions: { flexDirection: 'row', gap: 8, paddingHorizontal: 12, paddingVertical: 10, marginTop: 8, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border },
  reviewFileButton: { flex: 1, minHeight: 42, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7, borderRadius: 8, borderWidth: StyleSheet.hairlineWidth },
  reviewFileButtonApply: { backgroundColor: 'rgba(76,195,138,0.12)', borderColor: 'rgba(76,195,138,0.3)' },
  reviewFileButtonDiscard: { backgroundColor: 'rgba(239,100,97,0.08)', borderColor: 'rgba(239,100,97,0.28)' },
  reviewFileButtonPressed: { opacity: 0.7 },
  reviewFileButtonText: { fontFamily: 'Inter', fontSize: 12.5, fontWeight: '600' },
  reviewActions: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', paddingTop: 7 },
  prButton: { minHeight: 38, paddingHorizontal: 13, borderRadius: 7, backgroundColor: inset, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 7 },
  prButtonPrimary: { backgroundColor: accent },
  prButtonDisabled: { opacity: 0.45 },
  prButtonText: { color: ink, fontFamily: 'Inter', fontSize: 13, fontWeight: '600' },
  prButtonTextPrimary: { color: bg },
  prNavigationIcon: { width: 34, height: 40, alignItems: 'center', justifyContent: 'center' },
  prPublishForm: { gap: 10, marginTop: 5, alignItems: 'flex-start', alignSelf: 'stretch' },
  prCreateFooter: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginTop: 9 },
  prDraftToggle: { minHeight: 38, flexDirection: 'row', alignItems: 'center', gap: 9 },
  prDraftBox: { width: 18, height: 18, borderRadius: 4, borderWidth: 1, borderColor: muted, alignItems: 'center', justifyContent: 'center' },
  prDraftBoxChecked: { backgroundColor: ink, borderColor: ink },
  prHelp: { color: muted, fontFamily: 'Inter', fontSize: 12, lineHeight: 18 },
  prActionError: { paddingHorizontal: 16, paddingVertical: 10, backgroundColor: 'rgba(239,100,97,0.10)' },
  prHeader: { paddingHorizontal: 16, paddingTop: 18, paddingBottom: 17, gap: 7, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  prStatusLine: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  prState: { color: '#4CC38A', fontFamily: 'Inter', fontSize: 12, fontWeight: '600', textTransform: 'capitalize' },
  prNumber: { color: tertiary, fontFamily: 'Inter', fontSize: 12 },
  prTitle: { color: ink, fontFamily: 'Inter', fontSize: 18, fontWeight: '600', lineHeight: 22 },
  prMetadata: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  prAuthor: { color: muted, fontFamily: 'Inter', fontSize: 11 },
  prBranch: { flex: 1, minWidth: 0, color: tertiary, fontFamily: 'JetBrainsMono', fontSize: 10 },
  prStanding: { color: muted, fontFamily: 'Inter', fontSize: 12 },
  prCheckRow: { minHeight: 46, flexDirection: 'row', alignItems: 'center', gap: 9, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border, paddingVertical: 5 },
  prBody: { color: ink, fontFamily: 'Inter', fontSize: 14, lineHeight: 21 },
  prConversation: { gap: 4, paddingVertical: 7, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  prConversationAuthor: { color: ink, fontFamily: 'Inter', fontSize: 12, fontWeight: '600' },
  prConversationMeta: { color: tertiary, fontFamily: 'Inter', fontSize: 11, fontWeight: '400' },
  editorMeta: { color: tertiary, fontFamily: 'Inter', fontSize: 11 },
  editorAction: { minWidth: 35, height: 32, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 5 },
  editorActionText: { color: ink, fontFamily: 'Inter', fontSize: 12, fontWeight: '600' },
  editorCode: { paddingVertical: 14, paddingRight: 20 },
  editorLineNumbers: { color: '#676770', fontFamily: 'JetBrainsMono', fontSize: 11, lineHeight: 18, textAlign: 'right', paddingHorizontal: 11, minWidth: 48 },
  editorCodeText: { color: ink, fontFamily: 'JetBrainsMono', fontSize: 11, lineHeight: 18, paddingRight: 12 },
  editorInput: { flex: 1, minHeight: 500, color: ink, fontFamily: 'JetBrainsMono', fontSize: 11, lineHeight: 18, padding: 14 },
});
