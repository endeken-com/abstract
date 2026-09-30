import React, { useEffect, useState } from 'react';
import { Alert, AppState, FlatList, KeyboardAvoidingView, Linking, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { SafeAreaProvider, SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import * as Haptics from 'expo-haptics';
import { useFonts } from 'expo-font';
import { SymbolView } from 'expo-symbols';
import { MenuView } from '@react-native-menu/menu';
import { remote } from './remote';
import { ChatWorkspace } from './ChatWorkspace';
import { PullRequestIcon } from './PullRequestIcon';
import { FileIcon } from './FileIcon';
import { SwipeForward } from './SwipeForward';
import { useKeyboardHeight } from './useKeyboardVisible';
import { NativeSelect } from './NativeSelect';
import { ProviderLogo } from './ProviderLogo';
import { SyntaxCode } from './SyntaxCode';
import { TerminalView } from './TerminalView';
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
  settings: { ios: 'slider.horizontal.3', android: 'tune', web: 'tune' },
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
    <ScrollView contentContainerStyle={styles.railContent}>
      <RailAction icon="plus" title="New" onPress={() => navigate('NewChat', {})} />
      <RailAction icon="clock" title="Automations" onPress={() => navigate('Automations')} />
      <RailAction icon="branch" title="Worktrees" onPress={() => navigate('Worktrees')} />
      <RailAction icon="pull" title="Pull Requests" detail={prs ? String(prs) : undefined} onPress={() => navigate('PullRequests')} />
      {state.active && <Pressable onPress={() => navigate('Devices')} style={styles.railHost}><Icon name="devices" size={14} color={tertiary} /><Text numberOfLines={1} style={styles.railHostTitle}>{state.active.peer.name}</Text><View style={[styles.connectionDot, state.status !== 'online' && { backgroundColor: tertiary }]} /></Pressable>}
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
    </ScrollView>
    <Pressable onPress={() => navigate('Devices')} style={styles.railFooter}><Icon name="devices" /><Text numberOfLines={1} style={styles.railFooterTitle}>Devices</Text><Text numberOfLines={1} style={styles.railDetail}>{state.status === 'online' ? '1 connected' : state.active ? 'Connecting' : 'Connect'}</Text><View style={[styles.connectionDot, state.status !== 'online' && { backgroundColor: tertiary }]} /></Pressable>
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
  return <ScrollView style={styles.page} contentContainerStyle={styles.content}>
    <Text style={styles.title}>Pull Requests</Text>
    {prs.map(([sessionId, pr]) => <Pressable key={sessionId} style={styles.row} onPress={() => navigation.navigate('PullRequest', { sessionId })}><PullRequestIcon pr={pr} /><View style={{ flex: 1 }}><Text style={styles.rowTitle} numberOfLines={1}>{`#${pr.number}  ${pr.title}`}</Text><Text style={styles.subtitle}>{`${pr.standing || (pr.isDraft ? 'Draft' : pr.state)} · ${state.snapshot?.sessions.find(x => x.id === sessionId)?.name || ''}`}</Text></View><Icon name="chevron" size={12} /></Pressable>)}
    {!prs.length && <Empty text="No pull requests on this Mac." />}
  </ScrollView>;
}

function DevicesScreen() {
  const state = useRemote();
  const [address, setAddress] = useState('');
  const [advanced, setAdvanced] = useState(false);
  const connected = state.status === 'online' ? state.active : null;
  const nearby = state.nearby.filter(mac => mac.id !== connected?.peer.id);
  return <ScrollView style={styles.page} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
    <Text style={styles.title}>Macs</Text><Text style={styles.lead}>Your projects, chats, and terminals live on a Mac.</Text>
    {state.error ? <Text style={styles.error}>{state.error}</Text> : null}
    {state.pairingCode ? <View style={styles.callout}><Text style={styles.label}>Approve this code in Abstract on your Mac</Text><Text style={styles.code}>{state.pairingCode}</Text></View> : null}
    <View style={{ backgroundColor: panel, borderRadius: 16, padding: 18, flexDirection: 'row', alignItems: 'center', gap: 14, marginBottom: 23 }}>
      <View style={{ width: 50, height: 50, borderRadius: 13, backgroundColor: raised, alignItems: 'center', justifyContent: 'center' }}><Icon name="devices" size={27} color={ink} /></View>
      <View style={{ flex: 1 }}><Text style={{ color: ink, fontFamily: 'Inter', fontSize: 16, fontWeight: '600' }}>{connected?.peer.name || (state.status === 'connecting' ? 'Connecting…' : 'No Mac connected')}</Text><Text style={styles.subtitle}>{connected ? 'Connected and ready' : 'Choose a nearby or paired Mac'}</Text></View>
      {connected ? <MenuView actions={[{ id: 'disconnect', title: 'Disconnect', image: Platform.OS === 'ios' ? 'wifi.slash' : undefined }]} onPressAction={() => state.disconnect()}><View style={{ padding: 7 }}><Icon name="settings" size={18} /></View></MenuView> : <Icon name="devices" size={18} color={tertiary} />}
    </View>
    <Section title="Nearby"><Text style={styles.subtitle}>On your local network</Text>{nearby.length ? nearby.map(mac => <Row key={mac.id} title={mac.name} subtitle={state.devices.some(device => device.peer.id === mac.id) ? 'Paired · Tap to connect' : 'Tap to pair'} icon="devices" onPress={() => run(() => state.connect(mac.address, state.devices.find(x => x.peer.id === mac.id || x.peer.name === mac.name)))} />) : <Empty text="Searching… Open Abstract on your Mac and enable mobile sharing in Settings." />}</Section>
    {state.devices.length > 0 && <Section title="Your Macs">{state.devices.map(device => <View key={device.peer.id} style={{ flexDirection: 'row', alignItems: 'center' }}><View style={{ flex: 1 }}><Row title={device.peer.name} subtitle={device.peer.id === connected?.peer.id ? 'Connected' : device.address} icon="devices" onPress={() => run(() => state.connect(device.address, device))} trailing={device.peer.id === connected?.peer.id ? '●' : 'Connect'} /></View><MenuView actions={[{ id: 'forget', title: 'Forget Mac', image: Platform.OS === 'ios' ? 'trash' : undefined, attributes: { destructive: true } }]} onPressAction={() => Alert.alert('Forget this Mac?', device.peer.name, [{ text: 'Cancel' }, { text: 'Forget', style: 'destructive', onPress: () => run(() => state.forget(device.peer.id)) }])}><View style={{ paddingHorizontal: 10, paddingVertical: 16 }}><SymbolView name="ellipsis" size={17} tintColor={muted} /></View></MenuView></View>)}</Section>}
    <Pressable style={{ flexDirection: 'row', alignItems: 'center', paddingVertical: 14, gap: 8 }} onPress={() => setAdvanced(!advanced)}><Icon name="chevron" size={12} /><Text style={styles.sectionTitle}>Connect by address</Text></Pressable>
    {advanced && <View style={{ gap: 10 }}><Text style={styles.subtitle}>For a Mac reachable over VPN or the internet</Text><TextInput style={styles.input} value={address} onChangeText={setAddress} placeholder="mac.example.com:52000" placeholderTextColor={muted} autoCapitalize="none" keyboardType="url" /><Button title="Connect or pair" onPress={() => run(() => state.connect(address, state.devices.find(x => x.address === address)))} /></View>}
  </ScrollView>;
}

function ProjectsScreen({ navigation }: any) {
  const state = useRemote();
  return <ScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Projects</Text><Text style={styles.lead}>{state.active?.peer.name || 'Connect a Mac to see its projects'}</Text>
    {(state.snapshot?.projects || []).map(project => <Row key={project.id} title={project.name} subtitle={project.rootPath} onPress={() => navigation.navigate('Project', { projectId: project.id })} />)}
    {!state.snapshot?.projects.length && <Empty text="No projects available." />}
  </ScrollView>;
}
function ProjectScreen({ route, navigation }: any) {
  const state = useRemote();
  const project = state.snapshot?.projects.find(x => x.id === route.params.projectId) as Project | undefined;
  if (!project) return <View style={styles.content}><Empty text="Project unavailable." /></View>;
  const chats = state.snapshot?.sessions.filter(x => x.projectId === project.id && !x.archivedAt) || [];
  return <ScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>{project.name}</Text><Text style={styles.lead}>{project.rootPath}</Text>
    <View style={styles.actions}><Button title="New chat" onPress={() => navigation.navigate('NewChat', { projectId: project.id })} /><Button title="Worktrees" secondary onPress={() => navigation.navigate('Worktrees', { projectId: project.id })} /><Button title="Files" secondary onPress={() => navigation.navigate('Files', { root: project.rootPath })} /><Button title="Terminal" secondary onPress={() => navigation.navigate('Terminal', { root: project.rootPath })} /></View>
    <Section title="Chats">{chats.map(chat => <Row key={chat.id} title={chat.name} subtitle={`${chat.providerId} · ${chat.branch || chat.status}`} iconNode={<ProviderLogo provider={chat.providerId} size={16} />} onPress={() => navigation.navigate('Chat', { sessionId: chat.id })} trailing={chat.status} />)}{!chats.length && <Empty text="No chats in this project." />}</Section>
  </ScrollView>;
}
function ChatsScreen({ navigation }: any) {
  const state = useRemote();
  const chats = state.snapshot?.sessions.filter(x => !x.archivedAt).sort((a, b) => b.createdAt - a.createdAt) || [];
  return <ScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Chats</Text><Text style={styles.lead}>{state.active?.peer.name || 'Connect a Mac to see its chats'}</Text>{state.snapshot && <Button title="New standalone chat" onPress={() => navigation.navigate('NewChat', {})} />}
    {chats.map(chat => <Row key={chat.id} title={chat.name} subtitle={`${state.snapshot?.projects.find(p => p.id === chat.projectId)?.name || 'No project'} · ${chat.providerId}`} iconNode={<ProviderLogo provider={chat.providerId} size={16} />} trailing={chat.status} onPress={() => navigation.navigate('Chat', { sessionId: chat.id })} />)}
    {!chats.length && <Empty text="No chats available." />}
  </ScrollView>;
}
function NewChatScreen({ route, navigation }: any) {
  const state = useRemote(); const [prompt, setPrompt] = useState('');
  const [attachments, setAttachments] = useState<PickedAttachment[]>([]);
  const project = state.snapshot?.projects.find(x => x.id === route.params?.projectId);
  const [provider, setProvider] = useState(project?.defaultProviderId || state.snapshot?.providers[0] || 'claude');
  const [modelName, setModelName] = useState('');
  const [effort, setEffort] = useState('');
  const [policy, setPolicy] = useState(project?.defaultPermissionPolicy || 'ask');
  const [base, setBase] = useState(project?.defaultBaseRef || 'HEAD');
  const [worktree, setWorktree] = useState(route.params.worktree || '');
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    if (!prompt.trim()) return;
    setBusy(true);
    try {
      const response = project
        ? await state.request('startChat', { _0: { projectId: project.id, providerId: provider, prompt, ...attachmentPayload(attachments), baseRef: base || null, policy, model: modelName || null, effort: effort || null, worktree: worktree || null } })
        : await state.request('startStandaloneConfigured', { providerId: provider, prompt, policy,
          ...attachmentPayload(attachments), model: modelName || null, effort: effort || null });
      navigation.replace('Chat', { sessionId: response.started?.sessionId });
    } catch (error) { Alert.alert('Could not start chat', String(error)); } finally { setBusy(false); }
  };
  return <ScrollView style={styles.page} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled"><Text style={styles.label}>Agent</Text><View style={styles.choices}>{state.snapshot?.providers.map(name => <Pressable key={name} onPress={() => setProvider(name)} style={[styles.button, styles.secondary, { flexDirection: 'row', alignItems: 'center', gap: 7 }, provider === name && { backgroundColor: '#43434B' }]}><ProviderLogo provider={name} size={16} /><Text style={[styles.buttonText, { color: ink }]}>{name === 'claude' ? 'Claude Code' : name === 'codex' ? 'Codex' : name === 'opencode' ? 'OpenCode' : name}</Text></Pressable>)}</View>
    <Text style={styles.label}>Model (optional)</Text><View style={styles.choices}>{state.snapshot?.modelCatalogs?.[provider]?.models.map(option => <Button key={option.id} title={option.label} secondary={modelName !== option.id} onPress={() => { setModelName(option.id); setEffort(''); }} />)}</View><TextInput style={styles.input} value={modelName} onChangeText={setModelName} placeholder="Use agent default" placeholderTextColor={muted} autoCapitalize="none" />
    <Text style={styles.label}>Reasoning effort (optional)</Text><View style={styles.choices}>{state.snapshot?.modelCatalogs?.[provider]?.models.find(x => x.id === modelName)?.efforts.map(value => <Button key={value} title={value} secondary={effort !== value} onPress={() => setEffort(value)} />)}</View><TextInput style={styles.input} value={effort} onChangeText={setEffort} placeholder="Use model default" placeholderTextColor={muted} autoCapitalize="none" />
    {project && <><Text style={styles.label}>Base branch or ref</Text><TextInput style={styles.input} value={base} onChangeText={setBase} autoCapitalize="none" />
    <Text style={styles.label}>Existing worktree path (optional)</Text><TextInput style={styles.input} value={worktree} onChangeText={setWorktree} autoCapitalize="none" /></>}
    <Text style={styles.label}>Permissions</Text><View style={styles.choices}>{(['ask', 'auto-edits', 'bypass'] as const).map(value => <Button key={value} title={value} secondary={policy !== value} onPress={() => setPolicy(value)} />)}</View>
    <Text style={styles.label}>What should the agent do?</Text><TextInput style={[styles.input, styles.multiline]} value={prompt} onChangeText={setPrompt} multiline placeholder="Describe the task" placeholderTextColor={muted} />
    <Button title="Attach files or images" secondary onPress={() => run(async () => setAttachments(await pickAttachments(attachments)))} />{attachments.map(item => <Row key={item.id} title={item.title} subtitle={`${Math.ceil(item.size / 1024)} KB`} onPress={() => setAttachments(attachments.filter(x => x.id !== item.id))} trailing="Remove" />)}
    <Button title={busy ? 'Starting…' : 'Start chat'} onPress={() => run(submit)} />
  </ScrollView>;
}
function WorktreesScreen({ route, navigation }: any) {
  const state = useRemote(); const project = state.snapshot?.projects.find(x => x.id === route.params?.projectId);
  const [output, setOutput] = useState('');
  const refresh = () => { if (project) state.exec(project.rootPath, ['worktree', 'list', '--porcelain']).then(x => setOutput(x.stdout)).catch(error => setOutput(String(error))); };
  useEffect(refresh, [project?.id]);
  const entries = output.split(/\n\n+/).map(block => ({ path: block.match(/^worktree (.*)$/m)?.[1], branch: block.match(/^branch refs\/heads\/(.*)$/m)?.[1] })).filter(x => x.path);
  return <ScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Worktrees</Text>{!project ? <Section title="Projects">{state.snapshot?.projects.map(p => <Row key={p.id} title={p.name} subtitle={p.rootPath} onPress={() => navigation.navigate('Worktrees', { projectId: p.id })} />)}</Section> : <><Text style={styles.lead}>{project.name}</Text>{entries.map(entry => <View key={entry.path}><Row title={entry.branch || 'Detached'} subtitle={entry.path} onPress={() => navigation.navigate('Files', { root: entry.path })} /><Button title="Terminal" secondary onPress={() => navigation.navigate('Terminal', { root: entry.path })} />{entry.path !== project.rootPath && <><Button title="New chat here" secondary onPress={() => navigation.navigate('NewChat', { projectId: project.id, worktree: entry.path })} /><Button title="Remove worktree" danger onPress={() => Alert.alert('Remove worktree?', entry.path || '', [{ text: 'Cancel' }, { text: 'Remove', style: 'destructive', onPress: () => run(async () => { await state.request('removeWorktree', { projectId: project.id, path: entry.path, deleteBranch: false }); refresh(); }) }])} /></>}</View>)}{!entries.length && <Empty text="No worktrees found." />}</>}
    <Text style={styles.hint}>Create a chat to create a new worktree. Open a worktree to browse its files.</Text>
  </ScrollView>;
}
function FilesScreen({ route, navigation }: any) {
  const state = useRemote(); const root = route.params.root as string;
  const [paths, setPaths] = useState<string[]>([]); const [query, setQuery] = useState(''); const [folder, setFolder] = useState('');
  const [error, setError] = useState(''); const [loading, setLoading] = useState(false);
  const refresh = () => { setLoading(true); setError(''); state.request('listFiles', { root }).then(response => setPaths(response.files?._0 || [])).catch(reason => setError(String(reason.message || reason))).finally(() => setLoading(false)); };
  useEffect(() => { refresh(); }, [root]);
  const entries = query.trim()
    ? paths.filter(x => x.toLowerCase().includes(query.toLowerCase())).slice(0, 500).map(path => ({ path, name: path.split('/').at(-1) || path, directory: false }))
    : [...new Map(paths.filter(path => path.startsWith(folder ? `${folder}/` : '')).map(path => {
        const remainder = path.slice(folder ? folder.length + 1 : 0);
        const name = remainder.split('/')[0];
        const directory = remainder.includes('/');
        const child = folder ? `${folder}/${name}` : name;
        return [child, { path: child, name, directory }] as const;
      })).values()].sort((a, b) => Number(b.directory) - Number(a.directory) || a.name.localeCompare(b.name));
  return <SwipeForward enabled={!!route.params.sessionId} onSwipe={() => navigation.navigate('Terminal', { root, sessionId: route.params.sessionId })} onBack={() => navigation.goBack()}><View style={styles.page}>
    <View style={styles.paneToolbar}><View style={styles.fileFilter}><Icon name="filter" size={14} color={tertiary} /><TextInput style={styles.fileFilterInput} placeholder="Filter files" placeholderTextColor={tertiary} value={query} onChangeText={setQuery} />{query ? <Pressable onPress={() => setQuery('')} accessibilityLabel="Clear filter"><Icon name="close" size={13} /></Pressable> : null}</View><Pressable style={styles.paneIconButton} accessibilityLabel="Refresh files" onPress={refresh}><Icon name="refresh" size={17} /></Pressable></View>
    {folder ? <Pressable style={styles.breadcrumb} onPress={() => setFolder(folder.split('/').slice(0, -1).join('/'))}><Icon name="back" size={12} /><Text numberOfLines={1} style={styles.breadcrumbText}>{folder}</Text></Pressable> : null}
    {error ? <View style={styles.paneEmpty}><Icon name="failed" size={22} color="#EF6461" /><Text style={styles.paneEmptyTitle}>Couldn't load files</Text><Text style={styles.empty}>{error}</Text><Button title="Try again" secondary onPress={refresh} /></View> : loading && !paths.length ? <View style={styles.paneEmpty}><Text style={styles.empty}>Loading files…</Text></View> : <FlatList contentContainerStyle={styles.fileList} data={entries} keyExtractor={item => item.path} ListEmptyComponent={<View style={styles.paneEmpty}><Text style={styles.empty}>No files found.</Text></View>} renderItem={({ item }) => <Pressable style={styles.fileTreeRow} onPress={() => item.directory ? setFolder(item.path) : navigation.navigate('File', { path: root.replace(/\/$/, '') + '/' + item.path })}><FileIcon path={item.path} directory={item.directory} size={17} /><View style={{ flex: 1, minWidth: 0 }}><Text numberOfLines={1} style={styles.fileTreeTitle}>{item.name}</Text>{query ? <Text numberOfLines={1} style={styles.fileTreeSubtitle}>{item.path}</Text> : null}</View>{item.directory ? <Icon name="chevron" size={11} color={tertiary} /> : null}</Pressable>} />}
  </View></SwipeForward>;
}
function FileScreen({ route, navigation }: any) {
  const state = useRemote(); const path = route.params.path as string;
  const [content, setContent] = useState(''); const [editing, setEditing] = useState(false);
  useEffect(() => { state.readFile(path).then(setContent).catch(error => Alert.alert('File', String(error))); }, [path]);
  useEffect(() => { navigation.setOptions({ title: path.split('/').at(-1) || 'File' }); }, [navigation, path]);
  const save = async () => { await state.writeFile(path, content); setEditing(false); };
  const lines = content.split('\n');
  return <KeyboardAvoidingView style={styles.page} behavior={Platform.OS === 'ios' ? 'padding' : undefined}><View style={styles.paneToolbar}><FileIcon path={path} size={16} /><Text style={styles.editorMeta}>{content.length} characters · {lines.length} lines{editing ? ' · Editing' : ''}</Text><View style={{ flex: 1 }} /><Pressable style={styles.editorAction} onPress={() => editing ? run(save) : setEditing(true)}><Text style={styles.editorActionText}>{editing ? 'Save' : 'Edit'}</Text></Pressable>{editing && <Pressable style={styles.editorAction} onPress={() => { setEditing(false); state.readFile(path).then(setContent).catch(() => {}); }}><Text style={styles.editorActionText}>Cancel</Text></Pressable>}</View>
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
  return <SafeAreaView edges={['left', 'right', 'bottom']} style={styles.page}><SwipeForward enabled={!!route.params.sessionId} onSwipe={() => navigation.navigate('PullRequest', { sessionId: route.params.sessionId })} onBack={() => navigation.goBack()}><TerminalView id={id} root={root} /></SwipeForward></SafeAreaView>;
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
    <View style={styles.paneToolbar}><NativeSelect label="Review mode" value={committed ? 'Committed' : 'Uncommitted'} align="left" choices={[{ id: 'uncommitted', title: 'Uncommitted', selected: !committed }, { id: 'committed', title: 'Committed', selected: committed }]} onSelect={id => { setCommitted(id === 'committed'); setExpandedPaths([]); }} /><Text style={styles.diffAdded}>+{additions}</Text><Text style={styles.diffRemoved}>−{deletions}</Text><Pressable style={styles.paneIconButton} accessibilityLabel="Refresh review" onPress={refresh}><Icon name="refresh" size={17} /></Pressable><MenuView actions={[{ id: 'expand', title: 'Expand all files' }, { id: 'collapse', title: 'Collapse all files' }]} onPressAction={({ nativeEvent }) => setExpandedPaths(nativeEvent.event === 'expand' ? files.map(file => file.path) : [])}><View style={styles.paneIconButton}><SymbolView name={{ ios: 'ellipsis', android: 'more_horiz' }} size={19} tintColor={muted} /></View></MenuView></View>
    <ScrollView style={{ flex: 1 }} contentContainerStyle={styles.paneContent}>
      {error ? <View style={styles.paneEmpty}><Icon name="failed" size={22} color="#EF6461" /><Text style={styles.paneEmptyTitle}>Couldn't load changes</Text><Text style={styles.empty}>{error}</Text><Button title="Try again" secondary onPress={refresh} /></View> : null}
      {files.map(file => { const expanded = expandedPaths.includes(file.path); return <View key={file.path} style={styles.reviewFile}>
        <Pressable style={styles.reviewFileHeader} onPress={() => setExpandedPaths(expanded ? expandedPaths.filter(path => path !== file.path) : [...expandedPaths, file.path])}><Icon name="chevron" size={11} color={tertiary} /><FileIcon path={file.path} size={17} /><View style={{ flex: 1, minWidth: 0 }}><Text numberOfLines={1} style={styles.fileTreeTitle}>{file.path.split('/').at(-1)}</Text>{file.path.includes('/') && <Text numberOfLines={1} style={styles.fileTreeSubtitle}>{file.path.slice(0, file.path.lastIndexOf('/'))}</Text>}</View><Text style={styles.diffAdded}>+{file.additions}</Text><Text style={styles.diffRemoved}>−{file.deletions}</Text></Pressable>
        {expanded && <View style={styles.reviewFileBody}>{file.binary ? <Text style={styles.mono}>Binary file</Text> : <ScrollView horizontal><View>{patchLines(file.patch).map((line, index) => <Pressable key={index} onPress={() => { if (line.old !== null || line.next !== null) { setSelected({ path: file.path, line: line.next ?? line.old!, side: line.next !== null ? 'new' : 'old', code: line.text.slice(1) }); setCommentText(''); } }}><Text style={[styles.mono, styles.diffLine, line.kind === '+' && styles.addedLine, line.kind === '-' && styles.removedLine]}>{String(line.old ?? '').padStart(3)} {String(line.next ?? '').padStart(3)} {line.text}</Text></Pressable>)}</View></ScrollView>}<View style={styles.reviewActions}><Button title="Apply to project" secondary onPress={() => decide(file.path, true)} />{!committed && <Button title="Discard" danger onPress={() => decide(file.path, false)} />}</View></View>}
      </View>; })}
      {!files.length && !error && <View style={styles.paneEmpty}><Icon name="check" size={23} color={tertiary} /><Text style={styles.paneEmptyTitle}>No changes to display</Text><Text style={styles.empty}>{committed ? 'This branch has no committed changes.' : 'Nothing uncommitted in this worktree.'}</Text></View>}
      {selected && <PaneSection title={`Comment on ${selected.path}:${selected.line}`}><Text style={styles.mono}>{selected.code}</Text><TextInput style={[styles.input, styles.multiline]} multiline value={commentText} onChangeText={setCommentText} placeholder="Review comment" placeholderTextColor={muted} /><View style={styles.reviewActions}><Button title="Add comment" onPress={() => { if (commentText.trim()) setComments([...comments, { ...selected, text: commentText.trim() }]); setSelected(null); setCommentText(''); }} /><Button title="Cancel" secondary onPress={() => setSelected(null)} /></View></PaneSection>}
      {comments.length > 0 && <PaneSection title="Draft comments" detail={String(comments.length)}>{comments.map((comment, index) => <Row key={index} title={`${comment.path}:${comment.line}`} subtitle={comment.text} onPress={() => setComments(comments.filter((_, i) => i !== index))} trailing="Remove" />)}</PaneSection>}
      {(files.length > 0 || comments.length > 0) && <PaneSection title="Send review to agent"><TextInput style={[styles.input, styles.multiline]} multiline value={message} onChangeText={setMessage} placeholder="Optional summary" placeholderTextColor={muted} /><Button title="Send review" onPress={sendFeedback} /></PaneSection>}
    </ScrollView>
  </View></SwipeForward>;
}
function PullRequestScreen({ route }: any) {
  const state = useRemote(); const sessionId = route.params.sessionId as string;
  const chat = state.snapshot?.sessions.find(x => x.id === sessionId);
  const pr = state.snapshot?.pullRequests?.[sessionId];
  const [title, setTitle] = useState(chat?.name || ''); const [body, setBody] = useState('');
  const [base, setBase] = useState(chat?.baseRef || ''); const [draft, setDraft] = useState(false);
  const [message, setMessage] = useState('');
  const [publishOpen, setPublishOpen] = useState(false);
  const request = (name: string, args: Record<string, unknown> = {}) => run(() => state.request(name, { sessionId, ...args }));
  const checkSummary = pr?.checks?.length ? [
    `${pr.checks.filter(x => x.outcome === 'failed').length} failed`,
    `${pr.checks.filter(x => x.outcome === 'pending').length} running`,
    `${pr.checks.filter(x => x.outcome === 'passed').length} passed`,
  ].filter(x => !x.startsWith('0 ')).join(' · ') : undefined;
  return <ScrollView style={styles.page} contentContainerStyle={styles.paneContent}>
    {pr ? <>
      <View style={styles.prHeader}><View style={styles.prStatusLine}><PullRequestIcon pr={pr} size={15} /><Text style={styles.prState}>{pr.isDraft ? 'Draft' : pr.state}</Text><Text style={styles.prNumber}>#{pr.number}</Text><View style={{ flex: 1 }} />{pr.url && <Pressable accessibilityLabel="Open on GitHub" onPress={() => Linking.openURL(pr.url!).catch(() => {})}><SymbolView name={{ ios: 'arrow.up.forward.square', android: 'open_in_new' }} size={17} tintColor={muted} /></Pressable>}</View><Text style={styles.prTitle}>{pr.title}</Text><View style={styles.prMetadata}>{pr.author && <Text style={styles.prAuthor}>{pr.author}</Text>}<Text style={styles.prBranch} numberOfLines={1}>{pr.head || chat?.branch || 'Branch'} → {pr.base || chat?.baseRef || 'base'}</Text>{pr.additions != null && <Text style={styles.diffAdded}>+{pr.additions}</Text>}{pr.deletions != null && <Text style={styles.diffRemoved}>−{pr.deletions}</Text>}</View>{pr.reviewDecision && <Text style={styles.prStanding}>{({ APPROVED: 'Approved', CHANGES_REQUESTED: 'Changes requested', REVIEW_REQUIRED: 'Review required' } as Record<string, string>)[pr.reviewDecision] || pr.reviewDecision}</Text>}{pr.standing && <Text style={[styles.prStanding, pr.checks?.some(check => check.outcome === 'failed') && { color: '#EF6461' }]}>{pr.standing}</Text>}</View>
      {!!pr.checks?.length && <PaneSection title="Checks" detail={checkSummary}>{[...pr.checks].sort((a, b) => ({ failed: 0, pending: 1, passed: 2, skipped: 3 }[a.outcome] ?? 4) - ({ failed: 0, pending: 1, passed: 2, skipped: 3 }[b.outcome] ?? 4)).map(check => <Pressable key={`${check.workflow || ''}/${check.name}`} style={styles.prCheckRow} onPress={() => check.url && Linking.openURL(check.url).catch(() => {})}><Icon name={check.outcome === 'passed' ? 'check' : check.outcome === 'failed' ? 'failed' : check.outcome === 'pending' ? 'pending' : 'skipped'} size={14} color={check.outcome === 'failed' ? '#EF6461' : check.outcome === 'passed' ? '#4CC38A' : muted} /><View style={{ flex: 1 }}><Text style={styles.fileTreeTitle}>{check.name}</Text>{check.workflow && <Text style={styles.fileTreeSubtitle}>{check.workflow}</Text>}</View>{check.url && <SymbolView name={{ ios: 'arrow.up.right', android: 'open_in_new' }} size={12} tintColor={tertiary} />}</Pressable>)}</PaneSection>}
      {!!pr.body && <PaneSection title="Description"><Text style={styles.prBody}>{pr.body}</Text></PaneSection>}
      {!!((pr.reviews?.length || 0) + (pr.comments?.length || 0) + (pr.threads?.length || 0)) && <PaneSection title="Reviews" detail={pr.reviewDecision ? ({ APPROVED: 'Approved', CHANGES_REQUESTED: 'Changes requested', REVIEW_REQUIRED: 'Review required' } as Record<string, string>)[pr.reviewDecision] : undefined}>
        {(pr.reviews || []).map((review, index) => <View key={`review-${index}`} style={styles.prConversation}><Text style={styles.prConversationAuthor}>{review.author} <Text style={styles.prConversationMeta}>{review.verdict.toLowerCase().replaceAll('_', ' ')}</Text></Text>{review.body ? <Text style={styles.prBody}>{review.body}</Text> : null}</View>)}
        {(pr.threads || []).map(thread => <View key={thread.id} style={styles.prConversation}><Text style={styles.prConversationAuthor}>{thread.path}{thread.line ? `:${thread.line}` : ''} <Text style={styles.prConversationMeta}>{thread.isResolved ? 'Resolved' : thread.isOutdated ? 'Outdated' : 'Open thread'}</Text></Text>{thread.comments.map((comment, index) => <Text key={`${thread.id}-${index}`} style={styles.prBody}><Text style={styles.prConversationAuthor}>{comment.author}: </Text>{comment.body}</Text>)}</View>)}
        {(pr.comments || []).filter(comment => !comment.isBot).map((comment, index) => <View key={`comment-${index}`} style={styles.prConversation}><Text style={styles.prConversationAuthor}>{comment.author}</Text><Text style={styles.prBody}>{comment.body}</Text></View>)}
        {(pr.comments || []).filter(comment => comment.isBot).length > 0 && <Text style={styles.prConversationMeta}>{(pr.comments || []).filter(comment => comment.isBot).length} automated comments</Text>}
      </PaneSection>}
      {pr.state.toLowerCase() === 'open' && <PaneSection title="Actions"><View style={styles.reviewActions}><Button title="Commit and push" secondary onPress={() => setPublishOpen(!publishOpen)} />{pr.isDraft ? <Button title="Ready for review" onPress={() => request('markPullRequestReady')} /> : <MenuView title="Merge pull request" actions={(['squash', 'merge', 'rebase'] as const).map(method => ({ id: method, title: method === 'squash' ? 'Squash and merge' : method === 'merge' ? 'Create a merge commit' : 'Rebase and merge' }))} onPressAction={({ nativeEvent }) => { const method = nativeEvent.event; Alert.alert('Merge pull request?', `Use ${method} for #${pr.number}?`, [{ text: 'Cancel' }, { text: 'Merge', onPress: () => request('mergePullRequest', { method }) }]); }}><View style={styles.paneMenuButton}><Text style={styles.paneMenuLabel}>Merge</Text><Icon name="chevron" size={12} /></View></MenuView>}<Button title="Close" secondary onPress={() => Alert.alert('Close pull request?', pr.title, [{ text: 'Cancel' }, { text: 'Close', style: 'destructive', onPress: () => request('closePullRequest') }])} /></View>{publishOpen && <><TextInput style={styles.input} value={message} onChangeText={setMessage} placeholder="Commit message" placeholderTextColor={muted} /><Button title="Commit and push changes" onPress={() => message.trim() && request('pushChanges', { message: message.trim() })} /></>}</PaneSection>}
    </> : <PaneSection title="Create pull request"><Text style={styles.label}>Title</Text><TextInput style={styles.input} value={title} onChangeText={setTitle} /><Text style={styles.label}>Description</Text><TextInput style={[styles.input, styles.multiline]} value={body} onChangeText={setBody} multiline /><Text style={styles.label}>Base branch</Text><TextInput style={styles.input} value={base} onChangeText={setBase} autoCapitalize="none" /><MenuView actions={[{ id: 'ready', title: 'Ready for review', state: draft ? 'off' : 'on' }, { id: 'draft', title: 'Draft', state: draft ? 'on' : 'off' }]} onPressAction={({ nativeEvent }) => setDraft(nativeEvent.event === 'draft')}><View style={styles.paneMenuButton}><Text style={styles.paneMenuLabel}>{draft ? 'Draft' : 'Ready for review'}</Text><Icon name="chevron" size={12} /></View></MenuView><Button title="Create pull request" onPress={() => title.trim() && request('createPullRequest', { title: title.trim(), body, base: base || null, draft, commitFirst: true })} /></PaneSection>}
  </ScrollView>;
}
function AutomationsScreen({ navigation }: any) {
  const state = useRemote(); const automations = state.snapshot?.automations || [];
  return <ScrollView style={styles.page} contentContainerStyle={styles.content}><Text style={styles.title}>Automations</Text><Text style={styles.lead}>Scheduled on {state.active?.peer.name || 'a connected Mac'}.</Text><Button title="New automation" onPress={() => navigation.navigate('Automation', {})} />
    {automations.map(a => <Row key={a.id} title={a.name} subtitle={`${a.enabled ? 'Enabled' : 'Paused'} · ${a.providerId} · ${a.nextRunAt ? displayDate(a.nextRunAt) : 'Manual'}`} onPress={() => navigation.navigate('Automation', { id: a.id })} />)}{!automations.length && <Empty text="No automations on this Mac." />}
  </ScrollView>;
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
  return <ScrollView style={styles.page} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled"><Text style={styles.label}>Name</Text><TextInput style={styles.input} value={name} onChangeText={setName} placeholder="Automation name" placeholderTextColor={muted} />
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
  </ScrollView>;
}
export default function App() {
  const [fontsLoaded] = useFonts({ Inter: require('../assets/fonts/InterVariable.ttf'), JetBrainsMono: require('../assets/fonts/JetBrainsMono-Regular.ttf'), JetBrainsMonoMedium: require('../assets/fonts/JetBrainsMono-Medium.ttf') });
  useEffect(() => {
    remote.load();
    const appState = AppState.addEventListener('change', value => {
      if (value === 'active' && remote.active && remote.status === 'offline') remote.connect(remote.active.address, remote.active).catch(() => {});
      else if (value === 'active' && remote.status === 'online') remote.refresh().catch(() => {});
    });
    return () => appState.remove();
  }, []);
  if (!fontsLoaded) return null;
  return <SafeAreaProvider><StatusBar style="light" /><NavigationContainer theme={{ dark: true, colors: { primary: accent, background: bg, card: panel, text: ink, border, notification: accent }, fonts: { regular: { fontFamily: 'Inter', fontWeight: '400' }, medium: { fontFamily: 'Inter', fontWeight: '500' }, bold: { fontFamily: 'Inter', fontWeight: '700' }, heavy: { fontFamily: 'Inter', fontWeight: '900' } } }}>
      <Stack.Navigator initialRouteName="Sidebar" screenOptions={({ navigation }: any) => ({ headerStyle: { backgroundColor: panel }, headerTitleStyle: { fontFamily: 'Inter', fontSize: 15 }, headerTintColor: ink, contentStyle: { backgroundColor: bg }, headerShadowVisible: false, headerBackVisible: false, headerLeft: () => <ScreenNavigation navigation={navigation} />, scrollEdgeEffects: Platform.OS === 'ios' ? { top: 'soft' } : undefined, animation: 'slide_from_right', gestureEnabled: true, fullScreenGestureEnabled: true, animationMatchesGesture: true })}>
        <Stack.Screen name="Sidebar" component={SidebarScreen} options={{ headerShown: true, title: '', headerLeft: () => null, headerStyle: { backgroundColor: sidebar } }} />
        <Stack.Screen name="Devices" component={DevicesScreen} options={{ title: 'Devices' }} />
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
  fileFilter: { flex: 1, height: 40, backgroundColor: panel, borderRadius: 7, borderWidth: StyleSheet.hairlineWidth, borderColor: '#424249', flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 9 },
  fileFilterInput: { flex: 1, minWidth: 0, color: ink, fontFamily: 'Inter', fontSize: 13, paddingVertical: 0 },
  breadcrumb: { height: 30, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', gap: 7, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  breadcrumbText: { flex: 1, color: muted, fontFamily: 'Inter', fontSize: 11 },
  fileList: { paddingBottom: 24 },
  fileTreeRow: { minHeight: 50, paddingHorizontal: 16, paddingVertical: 7, flexDirection: 'row', alignItems: 'center', gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  fileTreeTitle: { color: ink, fontFamily: 'Inter', fontSize: 14.5, fontWeight: '500' },
  fileTreeSubtitle: { color: tertiary, fontFamily: 'Inter', fontSize: 10, marginTop: 2 },
  diffAdded: { color: '#4CC38A', fontFamily: 'JetBrainsMono', fontSize: 11 },
  diffRemoved: { color: '#EF6461', fontFamily: 'JetBrainsMono', fontSize: 11 },
  reviewFile: { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  reviewFileHeader: { minHeight: 60, paddingHorizontal: 13, paddingVertical: 7, flexDirection: 'row', alignItems: 'center', gap: 8 },
  reviewFileBody: { backgroundColor: panel, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border, paddingTop: 4 },
  diffLine: { minHeight: 19, paddingHorizontal: 12, lineHeight: 19 },
  addedLine: { color: '#8FCBAB', backgroundColor: 'rgba(76,195,138,0.08)' },
  removedLine: { color: '#E9A09D', backgroundColor: 'rgba(239,100,97,0.08)' },
  reviewActions: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', paddingTop: 7 },
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
