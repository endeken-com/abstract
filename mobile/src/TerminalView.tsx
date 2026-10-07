import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import WebView from 'react-native-webview';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import * as Haptics from 'expo-haptics';
import { remote } from './remote';
import { useKeyboardHeight } from './useKeyboardVisible';
import assets from './terminalAssets.json';

const html = `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"/><style>@font-face{font-family:JetBrainsMono;src:url(data:font/truetype;base64,${assets.font})}html,body,#terminal{margin:0;width:100%;height:100%;background:#1e1e21;overflow:hidden}*{box-sizing:border-box}${assets.css}</style></head><body><div id="terminal"></div><script>${assets.script}</script><script>${assets.fit}</script><script>
const terminal = new Terminal({cursorBlink:true,scrollback:5000,fontFamily:'JetBrainsMono, monospace',fontSize:12.5,lineHeight:1.2,theme:{background:'#1e1e21',foreground:'#c8c8ce',cursor:'#ececef',selectionBackground:'#5b9cf666',black:'#3e3e46',red:'#ef6461',green:'#4cc38a',yellow:'#e5a33a',blue:'#5b9cf6',magenta:'#c080e8',cyan:'#4ebfc7',white:'#c8c8ce',brightBlack:'#74747e',brightRed:'#ff8a86',brightGreen:'#72dba6',brightYellow:'#f5c26b',brightBlue:'#88b9ff',brightMagenta:'#d8a8f8',brightCyan:'#7dd8de',brightWhite:'#f4f4f6'}});
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

export function TerminalView({ id, root }: { id: number | null; root: string }) {
  const web = useRef<WebView>(null);
  const sent = useRef(0);
  const [ready, setReady] = useState(false);
  const [revision, setRevision] = useState(0);
  const [ctrl, setCtrl] = useState(false);
  const keyboard = useKeyboardHeight();
  const safeArea = useSafeAreaInsets();
  const [, render] = useState(0);
  useEffect(() => remote.subscribe(() => render(value => value + 1)), []);
  const output = id === null ? '' : remote.terminals[id] || '';
  useEffect(() => { sent.current = 0; setReady(false); setRevision(value => value + 1); }, [id]);
  useEffect(() => {
    if (!ready || !web.current) return;
    if (output.length < sent.current) sent.current = 0;
    const delta = output.slice(sent.current);
    if (delta) { web.current.injectJavaScript(`window.termWrite(${JSON.stringify(delta)});true;`); sent.current = output.length; }
  }, [ready, output]);
  const source = useMemo(() => ({ html, baseUrl: 'about:blank' }), []);
  const sendKey = (data: string, signal = false) => {
    if (id === null) return;
    if (signal) Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {});
    else Haptics.selectionAsync().catch(() => {});
    remote.terminalInput(id, data).catch(() => {});
    setCtrl(false);
  };
  return <View style={{ flex: 1, backgroundColor: '#1E1E21', paddingBottom: Platform.OS === 'ios' ? Math.max(0, keyboard - safeArea.bottom) : 0 }}>
    <View style={styles.locationBar}><View style={[styles.statusDot, !ready && styles.statusDotWaiting]} /><View style={styles.locationText}><Text style={styles.locationLabel}>{ready ? 'TERMINAL' : 'CONNECTING'}</Text><Text numberOfLines={1} ellipsizeMode="middle" style={styles.locationPath}>{root}</Text></View></View>
    {id === null ? <Text style={{ color: '#A4A4AD', padding: 12 }}>Opening terminal…</Text> : <WebView key={revision} ref={web} source={source} originWhitelist={['*']} javaScriptEnabled keyboardDisplayRequiresUserAction={false} scrollEnabled={false} bounces={false} style={{ flex: 1, backgroundColor: '#1E1E21' }} onMessage={event => {
      let message: any; try { message = JSON.parse(event.nativeEvent.data); } catch { return; }
      if (message.type === 'ready') setReady(true);
      if (message.type === 'input' && typeof message.data === 'string') {
        let data = message.data;
        if (ctrl && data.length === 1) {
          const character = data.toUpperCase().charCodeAt(0);
          if (character >= 64 && character <= 95) data = String.fromCharCode(character & 31);
          setCtrl(false);
        }
        remote.terminalInput(id, data).catch(() => {});
      }
      if (message.type === 'resize' && message.cols > 0 && message.rows > 0) remote.request('resizeTerminal', { id, cols: message.cols, rows: message.rows }).catch(() => {});
    }} />}
    <ScrollView horizontal keyboardShouldPersistTaps="always" showsHorizontalScrollIndicator={false} style={styles.commandRail} contentContainerStyle={styles.commandRailContent}>
      <View style={styles.keyGroup}><Text style={styles.groupLabel}>MODIFIER</Text><View style={styles.keyGroupRow}><CommandKey label="Ctrl" selected={ctrl} disabled={id === null} onPress={() => { Haptics.selectionAsync().catch(() => {}); setCtrl(!ctrl); }} /></View></View>
      {keyGroups.map(group => <View key={group.label} style={styles.keyGroup}><Text style={styles.groupLabel}>{group.label}</Text><View style={styles.keyGroupRow}>{group.keys.map(key => <CommandKey key={key.label} label={key.label} disabled={id === null} signal={group.label === 'SIGNALS'} onPress={() => sendKey(key.data, group.label === 'SIGNALS')} />)}</View></View>)}
    </ScrollView>
  </View>;
}

const styles = StyleSheet.create({
  locationBar: { minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 14, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: 'rgba(255,255,255,0.08)' },
  statusDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: '#4CC38A' },
  statusDotWaiting: { backgroundColor: '#75757E' },
  locationText: { flex: 1, minWidth: 0, gap: 2 },
  locationLabel: { color: '#A4A4AD', fontFamily: 'Inter', fontSize: 9, fontWeight: '700', letterSpacing: 0.7 },
  locationPath: { color: '#ECECEF', fontFamily: 'JetBrainsMono', fontSize: 11 },
  commandRail: { flexGrow: 0, backgroundColor: '#252529', borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: 'rgba(255,255,255,0.12)' },
  commandRailContent: { alignItems: 'center', paddingHorizontal: 12, paddingTop: 8, paddingBottom: 10, gap: 14 },
  keyGroup: { gap: 5 },
  groupLabel: { color: '#75757E', fontFamily: 'Inter', fontSize: 9, fontWeight: '700', letterSpacing: 0.7, paddingLeft: 2 },
  keyGroupRow: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  key: { minWidth: 43, height: 36, paddingHorizontal: 10, borderRadius: 7, backgroundColor: '#34343B', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.13)', alignItems: 'center', justifyContent: 'center' },
  keySelected: { backgroundColor: '#5B9CF6', borderColor: '#5B9CF6' },
  signalKey: { backgroundColor: '#3A3034', borderColor: 'rgba(239,100,97,0.24)' },
  keyPressed: { opacity: 0.65 },
  keyDisabled: { opacity: 0.45 },
  keyText: { color: '#ECECEF', fontFamily: 'JetBrainsMono', fontSize: 12 },
  keyTextSelected: { color: '#1E1E21' },
  signalKeyText: { color: '#EEA09E' },
});
