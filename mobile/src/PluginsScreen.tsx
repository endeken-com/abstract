import React, { useEffect, useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { useHeaderHeight } from '@react-navigation/elements';
import * as Haptics from 'expo-haptics';
import { remote, type RemoteClient } from './remote';
import { capabilityLine, setPluginEnabledArgs, setPluginTranscriptProjectsArgs, transcriptProjectNames } from './plugins';
import type { InstalledPlugin, PluginProjectChoice } from './types';
import type { PluginRoute } from './PluginView';

const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E';
const bg = '#1E1E21', panel = '#252529', inset = '#303036', border = 'rgba(255,255,255,0.075)';

function useRemote() {
  const [, rerender] = useState(0);
  useEffect(() => remote.subscribe(() => rerender(x => x + 1)), []);
  return remote;
}
function run(action: () => Promise<unknown>) { action().catch(error => Alert.alert('Abstract', String(error?.message || error))); }

function ProjectPicker({ choices, picked, onChange }: { choices: PluginProjectChoice[]; picked: string[]; onChange: (keys: string[]) => void }) {
  if (!choices.length) return <Text style={styles.note}>You have no projects yet, so it will read no messages.</Text>;
  return <View style={{ gap: 2 }}>{choices.map(choice => {
    const on = picked.includes(choice.key);
    return <Pressable key={choice.key} accessibilityRole="checkbox" accessibilityState={{ checked: on }} accessibilityLabel={choice.name}
      onPress={() => { Haptics.selectionAsync().catch(() => {}); onChange(on ? picked.filter(k => k !== choice.key) : [...picked, choice.key]); }} style={styles.projectRow}>
      <View style={[styles.box, on && styles.boxOn]}>{on && <Text style={styles.boxMark}>✓</Text>}</View>
      <Text style={styles.projectName}>{choice.name}</Text>
    </Pressable>;
  })}</View>;
}

function PluginRow({ mac, hostId, plugin, choices, online, navigation }: {
  mac: RemoteClient; hostId: string; plugin: InstalledPlugin; choices: PluginProjectChoice[]; online: boolean; navigation: any;
}) {
  const [reviewing, setReviewing] = useState(false);
  const [picking, setPicking] = useState(false);
  const [draftKeys, setDraftKeys] = useState(plugin.transcriptProjectKeys);
  const wantsTranscripts = plugin.requestedCapabilities.includes('transcripts.read');
  const names = transcriptProjectNames(plugin.transcriptProjectKeys, choices);
  const open = (params: Omit<PluginRoute, 'hostId' | 'pluginId'>) =>
    navigation.navigate('Plugin', { hostId, pluginId: plugin.id, ...params });
  const extra = plugin.contributions.filter(c => c.place !== 'main' && c.place !== 'home');

  return <View style={styles.plugin}>
    <View style={styles.pluginHead}>
      <View style={{ flex: 1 }}>
        <Text style={styles.name}>{plugin.name}</Text>
        <Text style={styles.detail}>Version {plugin.version} · {plugin.source === 'bundled' ? 'With Abstract' : 'Installed by you'}</Text>
      </View>
      <Switch value={plugin.usable} disabled={!online || !!plugin.problem}
        onValueChange={on => {
          if (on) { setDraftKeys(plugin.transcriptProjectKeys); setReviewing(true); }
          else run(() => mac.request('setPluginEnabled', setPluginEnabledArgs(plugin.id, false)));
        }} />
    </View>
    {plugin.description ? <Text style={styles.note}>{plugin.description}</Text> : null}
    {plugin.requestedCapabilities.length > 0 && <Text style={styles.note}>
      {plugin.requestedCapabilities.map(cap => capabilityLine(cap, names)).sort().join(' · ')}
    </Text>}
    {plugin.problem ? <Text style={[styles.note, { color: '#EF8582' }]}>{plugin.problem}</Text>
      : plugin.lastError ? <Text style={styles.note}>Last error: {plugin.lastError}</Text> : null}
    {plugin.appearances.length > 0 && <Text style={styles.note}>{plugin.appearances.join(' ')}</Text>}

    {reviewing && <View style={styles.review}>
      <Text style={styles.reviewTitle}>Turn on {plugin.name}?</Text>
      {plugin.source === 'user' && <Text style={styles.note}>It isn't signed. Its page cannot directly reach the network or files. The Mac checks each request against its grants.</Text>}
      <Text style={styles.reviewHead}>It will be able to:</Text>
      {plugin.requestedCapabilities.length === 0
        ? <Text style={styles.note}>Nothing beyond showing its own screen.</Text>
        : plugin.requestedCapabilities.map(cap => capabilityLine(cap, transcriptProjectNames(draftKeys, choices))).sort()
          .map(line => <Text key={line} style={styles.note}>{line}</Text>)}
      {wantsTranscripts && <>
        <Text style={styles.reviewHead}>It may read messages in:</Text>
        <ProjectPicker choices={choices} picked={draftKeys} onChange={setDraftKeys} />
        <Text style={styles.note}>It sees your messages, the agents' replies, tool names and file names — never file contents or what a tool printed. No projects picked means no messages at all.</Text>
      </>}
      <View style={styles.actions}>
        <Pressable accessibilityRole="button" style={styles.primary} onPress={() => run(async () => {
          await mac.request('setPluginEnabled', setPluginEnabledArgs(plugin.id, true, draftKeys));
          setReviewing(false);
        })}><Text style={styles.primaryText}>Enable</Text></Pressable>
        <Pressable accessibilityRole="button" style={styles.secondary} onPress={() => setReviewing(false)}><Text style={styles.secondaryText}>Cancel</Text></Pressable>
      </View>
    </View>}

    {plugin.usable && <View style={styles.actions}>
      {plugin.viewId && <Pressable accessibilityRole="button" style={styles.secondary}
        onPress={() => open({ title: plugin.viewTitle || plugin.name, place: 'main', contributionId: plugin.viewId! })}>
        <Text style={styles.secondaryText}>Open</Text></Pressable>}
      {extra.map(contribution => <Pressable key={`${contribution.place}:${contribution.id}`} accessibilityRole="button" style={styles.secondary}
        onPress={() => open({
          title: contribution.title, place: contribution.place, contributionId: contribution.id,
          invoke: contribution.place === 'chatMenu' || contribution.place === 'palette',
        })}><Text style={styles.secondaryText}>{contribution.title}</Text></Pressable>)}
      {wantsTranscripts && <Pressable accessibilityRole="button" style={styles.secondary}
        onPress={() => { setDraftKeys(plugin.transcriptProjectKeys); setPicking(!picking); }}>
        <Text style={styles.secondaryText}>Choose Projects…</Text></Pressable>}
    </View>}

    {picking && plugin.usable && <View style={styles.review}>
      <Text style={styles.reviewHead}>It may read messages in:</Text>
      <ProjectPicker choices={choices} picked={draftKeys} onChange={setDraftKeys} />
      <View style={styles.actions}>
        <Pressable accessibilityRole="button" style={styles.primary} onPress={() => run(async () => {
          await mac.request('setPluginTranscriptProjects', setPluginTranscriptProjectsArgs(plugin.id, draftKeys));
          setPicking(false);
        })}><Text style={styles.primaryText}>Save</Text></Pressable>
        <Pressable accessibilityRole="button" style={styles.secondary} onPress={() => setPicking(false)}><Text style={styles.secondaryText}>Cancel</Text></Pressable>
      </View>
    </View>}
  </View>;
}

export function PluginsScreen({ navigation }: any) {
  const state = useRemote();
  const headerHeight = useHeaderHeight();
  const macs = state.macs();
  return <ScrollView style={{ flex: 1, backgroundColor: bg }} contentContainerStyle={[styles.content, { paddingTop: headerHeight + 18 }]}>
    <Text style={styles.title}>Plugins</Text>
    <Text style={styles.lead}>Plugins are installed on your Macs. From here you can turn them on or off, choose what they may read, and open their screens. Install or remove one on the Mac.</Text>
    {!macs.length && <Text style={styles.note}>Pair a Mac to see its plugins.</Text>}
    {macs.map(mac => {
      const plugins = mac.snapshot?.plugins || [];
      const supported = mac.snapshot?.pluginsSupported === true || mac.snapshot?.plugins !== undefined;
      return <View key={mac.id} style={[styles.section, mac.state === 'unreachable' && { opacity: 0.45 }]}>
        <Text style={styles.sectionTitle}>{mac.name}</Text>
        {mac.state !== 'online' && <Text style={styles.note}>{mac.state === 'connecting' ? 'Connecting…' : `${mac.name} isn't reachable`}</Text>}
        {mac.snapshot && !supported
          ? <Text style={styles.note}>Update Abstract on this Mac to manage its plugins from your phone.</Text>
          : plugins.length
            ? plugins.map(plugin => <PluginRow key={plugin.id} mac={state.client(mac.id)} hostId={mac.id} plugin={plugin}
                choices={mac.snapshot?.pluginProjects || []} online={mac.state === 'online'} navigation={navigation} />)
            : <Text style={styles.note}>No plugins are installed on this Mac yet.</Text>}
      </View>;
    })}
    <Text style={styles.note}>A plugin sees only what you granted it. Turning it off takes that away and removes its screen, tabs, menu items and commands. Usage and message access are granted by turning a plugin on, and denied by turning it off — messages only ever come from the projects you pick.</Text>
  </ScrollView>;
}

const styles = StyleSheet.create({
  content: { padding: 18, gap: 16, paddingBottom: 32 },
  title: { color: ink, fontFamily: 'Inter', fontSize: 25, fontWeight: '600' },
  lead: { color: muted, fontFamily: 'Inter', fontSize: 14, lineHeight: 21 },
  section: { backgroundColor: panel, borderRadius: 8, padding: 14, gap: 9, borderWidth: StyleSheet.hairlineWidth, borderColor: border },
  sectionTitle: { color: muted, fontFamily: 'Inter', fontSize: 13.5, fontWeight: '600' },
  plugin: { gap: 6, paddingVertical: 8, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border },
  pluginHead: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  name: { color: ink, fontFamily: 'Inter', fontSize: 15.5, fontWeight: '500' },
  detail: { color: muted, fontFamily: 'Inter', fontSize: 12.5, marginTop: 3 },
  note: { color: muted, fontFamily: 'Inter', fontSize: 12.5, lineHeight: 18 },
  review: { backgroundColor: inset, borderRadius: 8, padding: 12, gap: 6, marginTop: 6 },
  reviewTitle: { color: ink, fontFamily: 'Inter', fontSize: 14, fontWeight: '600' },
  reviewHead: { color: ink, fontFamily: 'Inter', fontSize: 13, fontWeight: '600', marginTop: 4 },
  projectRow: { flexDirection: 'row', alignItems: 'center', gap: 9, minHeight: 36 },
  projectName: { color: ink, fontFamily: 'Inter', fontSize: 13.5 },
  box: { width: 19, height: 19, borderRadius: 4, borderWidth: 1, borderColor: tertiary, alignItems: 'center', justifyContent: 'center' },
  boxOn: { backgroundColor: ink, borderColor: ink },
  boxMark: { color: bg, fontSize: 12, fontWeight: '700' },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: 7, marginTop: 6 },
  primary: { backgroundColor: ink, borderRadius: 8, paddingHorizontal: 14, paddingVertical: 10 },
  primaryText: { color: bg, fontFamily: 'Inter', fontSize: 13, fontWeight: '600' },
  secondary: { backgroundColor: inset, borderRadius: 8, paddingHorizontal: 12, paddingVertical: 10 },
  secondaryText: { color: ink, fontFamily: 'Inter', fontSize: 13, fontWeight: '500' },
});
