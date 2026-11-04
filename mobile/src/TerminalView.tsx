import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import WebView from 'react-native-webview';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import * as Haptics from 'expo-haptics';
import { remote } from './remote';
import { useKeyboardHeight } from './useKeyboardVisible';
import assets from './terminalAssets.json';
import { themedStyles, palette, theme, useThemeVersion, type ThemeTokens } from './theme';

// The terminal page in the current theme: its canvas, text and 16 ANSI colours (ABS-185).
const terminalHtml = (t: ThemeTokens) => `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/><style>@font-face{font-family:JetBrainsMono;src:url(data:font/truetype;base64,${assets.font})}html,body,#terminal{margin:0;width:100%;height:100%;background:${t.canvas};overflow:hidden}*{box-sizing:border-box}${assets.css}</style></head><body><div id="terminal"></div><script>${assets.script}</script><script>${assets.fit}</script><script>
const terminal = new Terminal({cursorBlink:true,scrollback:5000,fontFamily:'JetBrainsMono, monospace',fontSize:12.5,lineHeight:1.2,theme:{background:'${t.canvas}',foreground:'${t.terminalWhite}',cursor:'${t.text}',selectionBackground:'${t.terminalBlue}66',black:'${t.terminalBlack}',red:'${t.terminalRed}',green:'${t.terminalGreen}',yellow:'${t.terminalYellow}',blue:'${t.terminalBlue}',magenta:'${t.terminalMagenta}',cyan:'${t.terminalCyan}',white:'${t.terminalWhite}',brightBlack:'${t.terminalBrightBlack}',brightRed:'${t.terminalBrightRed}',brightGreen:'${t.terminalBrightGreen}',brightYellow:'${t.terminalBrightYellow}',brightBlue:'${t.terminalBrightBlue}',brightMagenta:'${t.terminalBrightMagenta}',brightCyan:'${t.terminalBrightCyan}',brightWhite:'${t.terminalBrightWhite}'}});
const fit = new FitAddon.FitAddon(); terminal.loadAddon(fit); terminal.open(document.getElementById('terminal'));
const post=(type,fields={})=>window.ReactNativeWebView.postMessage(JSON.stringify({type,...fields}));
terminal.onData(data=>post('input',{data}));
window.termWrite=data=>terminal.write(data);
let previousSize=''; const resize=()=>{fit.fit(); const size=terminal.cols+','+terminal.rows;if(size!==previousSize){previousSize=size;post('resize',{cols:terminal.cols,rows:terminal.rows})}};
new ResizeObserver(resize).observe(document.getElementById('terminal'));
document.getElementById('terminal').addEventListener('touchstart',()=>terminal.focus(),{passive:true});
setTimeout(()=>{resize();post('ready')},50);
</script></body></html>`;

const keyGroups = [
  { label: 'KEYS', keys: [{ label: 'Esc', data: '\x1b' }, { label: 'Tab', data: '\t' }] },
  { label: 'MOVE', keys: [{ label: '←', data: '\x1b[D' }, { label: '↑', data: '\x1b[A' }, { label: '↓', data: '\x1b[B' }, { label: '→', data: '\x1b[C' }] },
  { label: 'POSITION', keys: [{ label: 'Home', data: '\x1b[H' }, { label: 'End', data: '\x1b[F' }, { label: 'PgUp', data: '\x1b[5~' }, { label: 'PgDn', data: '\x1b[6~' }] },
  { label: 'SIGNALS', keys: [{ label: 'Ctrl+C', data: '\x03' }, { label: 'Ctrl+D', data: '\x04' }, { label: 'Ctrl+Z', data: '\x1a' }] },
];
function CommandKey({ label, onPress, selected, signal, disabled }: { label: string; onPress: () => void; selected?: boolean; signal?: boolean; disabled?: boolean }) {
  return <Pressable accessibilityRole="button" accessibilityLabel={label} accessibilityState={{ selected: !!selected, disabled: !!disabled }} disabled={disabled} onPress={onPress} style={({ pressed }) => [styles.key, selected && styles.keySelected, signal && styles.signalKey, pressed && styles.keyPressed, disabled && styles.keyDisabled]}><Text style={[styles.keyText, selected && styles.keyTextSelected, signal && styles.signalKeyText]}>{label}</Text></Pressable>;
}

export function TerminalView({ hostId, id, root }: { hostId: string; id: number | null; root: string }) {
  const mac = remote.client(hostId);
  const web = useRef<WebView>(null);
  const sent = useRef(0);
  const [ready, setReady] = useState(false);
  const [revision, setRevision] = useState(0);
  const [ctrl, setCtrl] = useState(false);
  const keyboard = useKeyboardHeight();
  const safeArea = useSafeAreaInsets();
  const [, render] = useState(0);
  useEffect(() => remote.subscribe(() => render(value => value + 1)), []);
  const output = id === null ? '' : mac.terminals[id] || '';
  useEffect(() => { sent.current = 0; setReady(false); setRevision(value => value + 1); }, [id]);
  useEffect(() => {
    if (!ready || !web.current) return;
    if (output.length < sent.current) sent.current = 0;
    const delta = output.slice(sent.current);
    if (delta) { web.current.injectJavaScript(`window.termWrite(${JSON.stringify(delta)});true;`); sent.current = output.length; }
  }, [ready, output]);
  const themeVersion = useThemeVersion();
  const source = useMemo(() => ({ html: terminalHtml(theme().tokens), baseUrl: 'about:blank' }), [themeVersion]);
  const sendKey = (data: string, signal = false) => {
    if (id === null) return;
    if (signal) Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {});
    else Haptics.selectionAsync().catch(() => {});
    mac.terminalInput(id, data).catch(() => {});
    setCtrl(false);
  };
  return <View style={{ flex: 1, backgroundColor: palette.canvas, paddingBottom: Platform.OS === 'ios' ? Math.max(0, keyboard - safeArea.bottom) : 0 }}>
    <View style={styles.locationBar}><View style={[styles.statusDot, !ready && styles.statusDotWaiting]} /><View style={styles.locationText}><Text style={styles.locationLabel}>{ready ? 'TERMINAL' : 'CONNECTING'}</Text><Text numberOfLines={1} ellipsizeMode="middle" style={styles.locationPath}>{root}</Text></View></View>
    {id === null ? <Text style={{ color: palette.textSecondary, padding: 12 }}>Opening terminal…</Text> : <WebView key={revision} ref={web} source={source} originWhitelist={['*']} javaScriptEnabled keyboardDisplayRequiresUserAction={false} scrollEnabled={false} bounces={false} style={{ flex: 1, backgroundColor: palette.canvas }} onMessage={event => {
      let message: any; try { message = JSON.parse(event.nativeEvent.data); } catch { return; }
      if (message.type === 'ready') setReady(true);
      if (message.type === 'input' && typeof message.data === 'string') {
        let data = message.data;
        if (ctrl && data.length === 1) {
          const character = data.toUpperCase().charCodeAt(0);
          if (character >= 64 && character <= 95) data = String.fromCharCode(character & 31);
          setCtrl(false);
        }
        mac.terminalInput(id, data).catch(() => {});
      }
      if (message.type === 'resize' && message.cols > 0 && message.rows > 0) mac.request('resizeTerminal', { id, cols: message.cols, rows: message.rows }).catch(() => {});
    }} />}
    <ScrollView horizontal keyboardShouldPersistTaps="always" showsHorizontalScrollIndicator={false} style={styles.commandRail} contentContainerStyle={styles.commandRailContent}>
      <View style={styles.keyGroup}><Text style={styles.groupLabel}>MODIFIER</Text><View style={styles.keyGroupRow}><CommandKey label="Ctrl" selected={ctrl} disabled={id === null} onPress={() => { Haptics.selectionAsync().catch(() => {}); setCtrl(!ctrl); }} /></View></View>
      {keyGroups.map(group => <View key={group.label} style={styles.keyGroup}><Text style={styles.groupLabel}>{group.label}</Text><View style={styles.keyGroupRow}>{group.keys.map(key => <CommandKey key={key.label} label={key.label} disabled={id === null} signal={group.label === 'SIGNALS'} onPress={() => sendKey(key.data, group.label === 'SIGNALS')} />)}</View></View>)}
    </ScrollView>
  </View>;
}

const styles = themedStyles(() => StyleSheet.create({
  locationBar: { minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 14, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: 'rgba(255,255,255,0.08)' },
  statusDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: palette.added },
  statusDotWaiting: { backgroundColor: palette.textTertiary },
  locationText: { flex: 1, minWidth: 0, gap: 2 },
  locationLabel: { color: palette.textSecondary, fontFamily: 'Inter', fontSize: 9, fontWeight: '700', letterSpacing: 0.7 },
  locationPath: { color: palette.text, fontFamily: 'JetBrainsMono', fontSize: 11 },
  commandRail: { flexGrow: 0, backgroundColor: palette.surface, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: palette.borderStrong },
  commandRailContent: { alignItems: 'center', paddingHorizontal: 12, paddingTop: 8, paddingBottom: 10, gap: 14 },
  keyGroup: { gap: 5 },
  groupLabel: { color: palette.textTertiary, fontFamily: 'Inter', fontSize: 9, fontWeight: '700', letterSpacing: 0.7, paddingLeft: 2 },
  keyGroupRow: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  key: { minWidth: 43, height: 36, paddingHorizontal: 10, borderRadius: 7, backgroundColor: palette.inset, borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.13)', alignItems: 'center', justifyContent: 'center' },
  keySelected: { backgroundColor: palette.terminalBlue, borderColor: palette.terminalBlue },
  signalKey: { backgroundColor: palette.removedWash, borderColor: palette.removed },
  keyPressed: { opacity: 0.65 },
  keyDisabled: { opacity: 0.45 },
  keyText: { color: palette.text, fontFamily: 'JetBrainsMono', fontSize: 12 },
  keyTextSelected: { color: palette.canvas },
  signalKeyText: { color: palette.removed },
}));
