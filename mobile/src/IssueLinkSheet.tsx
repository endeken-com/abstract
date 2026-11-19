import React, { useEffect, useRef, useState } from 'react';
import { Alert, Image, KeyboardAvoidingView, Modal, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { SvgXml } from 'react-native-svg';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Buffer } from 'buffer';
import { BrandLoadingIndicator } from './Brand';
import type { RemoteClient } from './remote';
import type { PickedAttachment } from './attachments';
import { knownIconVersions, legacyGitHubArgs, legacyGitHubGroup, linkMenuActions, linkSourceOf, namesGroups, pickedFromMac, rememberIcons, searchPlaceholder, searchRequest, sheetTitle, trackerIcon, type IssueGroup, type IssueResult, type IssueSources, type LinkSource } from './issueLinks';
import { onTheme, themedStyles, palette } from './theme';

let ink = '', muted = '', tertiary = '', canvas = '', panel = '', raised = '', border = '';
onTheme(t => { ink = t.text; muted = t.textSecondary; tertiary = t.textTertiary; canvas = t.canvas; panel = t.surface; raised = t.surfaceRaised; border = t.border; });

// What each Mac said a project or chat offers, kept while the app runs so the
// menu still names them (disabled) when that Mac isn't reachable.
const kept = new Map<string, IssueSources>();

/// A tracker's mark as its plugin draws it, or a plain ticket when the
/// phone hasn't been sent it. One-colour marks take the text colour; Jira's keeps its own.
export function TrackerIcon({ trackerId, size = 13, color }: { trackerId?: string | null; size?: number; color?: string }) {
  const icon = trackerIcon(trackerId);
  const tint = color || muted;
  if (icon?.format === 'svg') {
    // A one-colour mark that names no fill (Linear's) would draw black: give it the text colour.
    const raw = Buffer.from(icon.data, 'base64').toString('utf8');
    const xml = icon.template ? raw.replace(/<svg\b(?![^>]*\sfill=)/i, '<svg fill="currentColor"') : raw;
    return <SvgXml xml={xml} width={size} height={size} color={icon.template ? tint : undefined} />;
  }
  if (icon?.format === 'png') return <Image source={{ uri: `data:image/png;base64,${icon.data}` }} style={{ width: size, height: size, tintColor: icon.template ? tint : undefined }} />;
  return <SymbolView name={{ ios: 'ticket', android: 'confirmation_number', web: 'confirmation_number' } as any} size={size} tintColor={tint} style={{ width: size, height: size }} />;
}

/// The glyph an attachment chip leads with: the tracker's mark for its issues.
export function AttachmentGlyph({ kind, tracker, size = 12 }: { kind: string; tracker?: string | null; size?: number }) {
  if (kind === 'trackerIssue') return <TrackerIcon trackerId={tracker} size={size} />;
  const symbol = kind === 'pullRequest' ? { ios: 'arrow.triangle.pull', android: 'merge' } : kind === 'githubIssue' ? { ios: 'smallcircle.filled.circle', android: 'adjust' } : kind === 'image' ? { ios: 'photo', android: 'image' } : { ios: 'doc', android: 'description' };
  return <SymbolView name={{ ...symbol, web: symbol.android } as any} size={size} tintColor={muted} style={{ width: size, height: size }} />;
}

type Scope = { mac: RemoteClient; hostId: string | null; macName: string; projectId: string | null; chatId: string | null; root: string | null };

/// The link items of a composer's "Add to message" menu and the sheet they
/// open (ABS-211): what the Mac's composer offers for the project, asked of
/// that Mac. Picking an issue completes it there and adds it to `attachments`.
export function useIssueLinks({ mac, hostId, macName, projectId, chatId, root, attachments, setAttachments }: Scope & { attachments: PickedAttachment[]; setAttachments: (next: PickedAttachment[]) => void }) {
  const key = `${hostId}|${projectId || ''}|${chatId || ''}`;
  const online = mac.status === 'online';
  const supported = mac.snapshot?.issueSearch === true;
  const [sources, setSources] = useState<IssueSources | null>(kept.get(key) || null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<LinkSource | null>(null);
  useEffect(() => { setSources(kept.get(key) || null); setError(null); }, [key]);
  useEffect(() => {
    if (!online || !supported) return;
    let active = true;
    mac.request('issueSources', { projectId, chatId, iconVersions: knownIconVersions() }).then(reply => {
      const found = reply.issueSources?._0 as IssueSources | undefined;
      if (!active || !found) return;
      rememberIcons(found);
      kept.set(key, found);
      setSources(found);
      setError(null);
    }, failure => { if (active) setError(String(failure?.message || failure)); });
    return () => { active = false; };
  }, [key, online, supported]);
  const actions = linkMenuActions({ supported, online, macName, sources, error, hasRepository: !!root, platform: Platform.OS });
  const handle = (event: string) => {
    const source = linkSourceOf(event);
    if (!source) return false;
    setOpen(source);
    return true;
  };
  const add = (attachment: PickedAttachment) => {
    if (attachments.some(item => item.url && item.url === attachment.url)) return;
    setAttachments([...attachments, attachment]);
  };
  const sheet = open && <IssueSearchSheet source={open} sources={sources} scope={{ mac, hostId, macName, projectId, chatId, root }} supported={supported} attached={new Set(attachments.map(item => item.url || ''))} pick={attachment => { add(attachment); setOpen(null); }} close={() => setOpen(null)} />;
  return { actions, handle, sheet, sources };
}

/// Searches as you type, results grouped by tracker under its mark. A key
/// or a link pasted whole finds that one issue.
function IssueSearchSheet({ source, sources, scope, supported, attached, pick, close }: { source: LinkSource; sources: IssueSources | null; scope: Scope; supported: boolean; attached: Set<string>; pick: (attachment: PickedAttachment) => void; close: () => void }) {
  const ios = Platform.OS === 'ios';
  const [query, setQuery] = useState('');
  const [groups, setGroups] = useState<IssueGroup[]>([]);
  const [problem, setProblem] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [completing, setCompleting] = useState<string | null>(null);
  const generation = useRef(0);
  const search = async (text: string) => {
    const mine = ++generation.current;
    setLoading(true);
    try {
      let found: IssueGroup[];
      if (supported) {
        const { name, args } = searchRequest(source, text, scope);
        found = (await scope.mac.request(name, args, 45000)).issueGroups?._0 || [];
      } else {
        // An older Mac: GitHub through its `gh`, as before.
        if (!scope.root) throw Error('This chat has no repository to search.');
        const reply = await scope.mac.request('exec', { command: 'gh', args: legacyGitHubArgs(source, text), cwd: scope.root });
        const output = reply.exec?._0;
        if (output?.code !== 0) throw Error(output?.stderr || 'Could not search GitHub.');
        found = [legacyGitHubGroup(source, JSON.parse(output.stdout || '[]'))];
      }
      if (mine !== generation.current) return;
      setGroups(found);
      setProblem(null);
    } catch (failure: any) {
      if (mine !== generation.current) return;
      setGroups([]);
      setProblem(String(failure?.message || failure));
    } finally { if (mine === generation.current) setLoading(false); }
  };
  // Debounced, so each keystroke doesn't ask every tracker.
  useEffect(() => {
    const timer = setTimeout(() => { search(query); }, query ? 350 : 0);
    return () => clearTimeout(timer);
  }, [query]);
  const choose = async (result: IssueResult) => {
    if (completing) return;
    if (result.attachment.kind !== 'trackerIssue' || !supported) { pick(pickedFromMac(result.attachment)); return; }
    // A search lists issues without their descriptions: ask for it whole,
    // and if that fails attach it as it was listed, as the Mac does.
    setCompleting(result.attachment.url || result.reference);
    try {
      const reply = await scope.mac.request('completeIssue', { _0: result.attachment }, 45000);
      pick(pickedFromMac(reply.attachment?._0 || result.attachment));
    } catch (failure) {
      pick(pickedFromMac(result.attachment));
      Alert.alert('Attached as listed', `${result.reference} couldn't be read whole from ${scope.macName}, so it goes without its description. ${String((failure as any)?.message || failure)}`);
    } finally { setCompleting(null); }
  };
  const named = namesGroups(source, groups);
  const empty = !loading && !problem && groups.every(group => !group.results.length && !group.problem);
  return <Modal visible animationType="slide" presentationStyle={ios ? 'pageSheet' : 'overFullScreen'} transparent={!ios} onRequestClose={close}>
    <KeyboardAvoidingView style={ios ? styles.root : styles.backdrop} behavior={ios ? 'padding' : undefined}>
      {!ios && <Pressable style={StyleSheet.absoluteFill} onPress={close} accessibilityLabel="Close search" />}
      <SafeAreaView edges={['bottom']} style={[styles.panel, ios && { flex: 1, maxHeight: '100%' }]}>
        <View style={styles.handle} />
        <View style={styles.header}><Text style={styles.title}>{sheetTitle(sources, source)}</Text><Pressable accessibilityRole="button" accessibilityLabel="Close" onPress={close} style={styles.close}><SymbolView name={{ ios: 'xmark', android: 'close', web: 'close' } as any} size={17} tintColor={ink} style={{ width: 17, height: 17 }} /></Pressable></View>
        <View style={styles.search}><SymbolView name={{ ios: 'magnifyingglass', android: 'search', web: 'search' } as any} size={17} tintColor={tertiary} style={{ width: 17, height: 17 }} /><TextInput autoFocus value={query} onChangeText={setQuery} onSubmitEditing={() => search(query)} returnKeyType="search" autoCapitalize="none" autoCorrect={false} placeholder={searchPlaceholder(sources, source)} placeholderTextColor={tertiary} accessibilityLabel="Search" style={styles.input} />{loading && <BrandLoadingIndicator size={16} color={muted} decorative />}</View>
        <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={styles.results}>
          {!!problem && <Text accessibilityRole="alert" style={styles.problem}>{problem}</Text>}
          {groups.map(group => <View key={group.sourceId}>
            {named && <View accessibilityRole="header" style={styles.group}>{source.kind === 'tracker' && <TrackerIcon trackerId={group.sourceId} size={14} />}<Text style={styles.groupTitle}>{group.title}</Text></View>}
            {!!group.problem && <Text accessibilityRole="alert" style={styles.problem}>{group.problem}</Text>}
            {group.results.map(result => {
              const busy = completing === (result.attachment.url || result.reference);
              const done = !!result.attachment.url && attached.has(result.attachment.url);
              return <Pressable accessibilityRole="button" accessibilityLabel={`${result.reference} ${result.title}${result.state ? `, ${result.state}` : ''}`} accessibilityState={{ busy, disabled: done }} disabled={done || !!completing} key={`${group.sourceId}:${result.reference}`} onPress={() => choose(result)} style={[styles.result, done && { opacity: 0.45 }]}>
                <Text style={styles.reference}>{result.reference}</Text>
                <View style={{ flex: 1 }}><Text numberOfLines={2} style={styles.resultTitle}>{result.title}</Text>{!!result.state && <Text style={styles.meta}>{result.state}</Text>}</View>
                {busy ? <BrandLoadingIndicator size={14} color={muted} decorative /> : null}
              </Pressable>;
            })}
          </View>)}
          {empty && <Text style={styles.empty}>{query.trim() ? 'No results' : source.kind === 'tracker' ? 'No open issues assigned to you.' : source.kind === 'pullRequest' ? 'No open pull requests.' : 'No open issues.'}</Text>}
        </ScrollView>
      </SafeAreaView>
    </KeyboardAvoidingView>
  </Modal>;
}

/// An attachment's chip in a sent message: the tracker's mark and the issue's key and title.
export function SentAttachmentChip({ kind, label, tracker }: { kind: string; label: string; tracker?: string | null }) {
  return <View accessible accessibilityLabel={label} style={styles.chip}><AttachmentGlyph kind={kind} tracker={tracker} /><Text numberOfLines={1} style={styles.chipLabel}>{label}</Text></View>;
}

const styles = themedStyles(() => StyleSheet.create({
  root: { flex: 1, backgroundColor: canvas },
  backdrop: { flex: 1, justifyContent: 'flex-end', backgroundColor: 'rgba(0,0,0,0.55)' },
  panel: { backgroundColor: canvas, minHeight: 390, maxHeight: '85%', borderTopLeftRadius: 18, borderTopRightRadius: 18, paddingHorizontal: 16 },
  handle: { alignSelf: 'center', width: 36, height: 4, borderRadius: 2, backgroundColor: palette.textTertiary, marginTop: 10, marginBottom: 12 },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 15 },
  title: { color: ink, fontFamily: 'Inter', fontSize: 19, fontWeight: '600' },
  close: { width: 38, height: 38, borderRadius: 19, backgroundColor: raised, alignItems: 'center', justifyContent: 'center' },
  search: { minHeight: 50, borderRadius: 10, backgroundColor: panel, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 12 },
  input: { flex: 1, minWidth: 0, color: ink, fontFamily: 'Inter', fontSize: 15 },
  results: { paddingTop: 12, paddingBottom: 25 },
  group: { flexDirection: 'row', alignItems: 'center', gap: 7, paddingTop: 12, paddingBottom: 4 },
  groupTitle: { color: muted, fontFamily: 'Inter', fontSize: 12, fontWeight: '600' },
  problem: { color: muted, fontFamily: 'Inter', fontSize: 13, lineHeight: 19, paddingVertical: 8 },
  result: { minHeight: 62, flexDirection: 'row', alignItems: 'center', gap: 12, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: border },
  reference: { color: muted, fontFamily: 'JetBrainsMono', fontSize: 12 },
  resultTitle: { color: ink, fontFamily: 'Inter', fontSize: 14.5, lineHeight: 20 },
  meta: { color: tertiary, fontFamily: 'Inter', fontSize: 11, marginTop: 2 },
  empty: { color: tertiary, fontFamily: 'Inter', fontSize: 13, textAlign: 'center', paddingTop: 28 },
  chip: { flexDirection: 'row', alignItems: 'center', gap: 5, maxWidth: '94%', paddingHorizontal: 9, paddingVertical: 6, borderRadius: 8, backgroundColor: raised },
  chipLabel: { flexShrink: 1, color: muted, fontFamily: 'Inter', fontSize: 12, fontWeight: '500' },
}));
