import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Platform, Pressable, ScrollView, Text, View } from 'react-native';
import WebView from 'react-native-webview';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
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

const keys = [
  { label: 'Ctrl+C', data: '\x03' }, { label: 'Ctrl+D', data: '\x04' }, { label: 'Ctrl+Z', data: '\x1a' },
  { label: 'Esc', data: '\x1b' }, { label: 'Tab', data: '\t' },
  { label: '↑', data: '\x1b[A' }, { label: '↓', data: '\x1b[B' },
  { label: '←', data: '\x1b[D' }, { label: '→', data: '\x1b[C' },
  { label: 'Home', data: '\x1b[H' }, { label: 'End', data: '\x1b[F' },
  { label: 'PgUp', data: '\x1b[5~' }, { label: 'PgDn', data: '\x1b[6~' },
];

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
  return <View style={{ flex: 1, backgroundColor: '#1E1E21', paddingBottom: Platform.OS === 'ios' ? Math.max(0, keyboard - safeArea.bottom) : 0 }}>
    <Text numberOfLines={1} style={{ color: '#75757E', fontFamily: 'JetBrainsMono', fontSize: 10, paddingHorizontal: 12, paddingVertical: 9 }}>{root}</Text>
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
    <ScrollView horizontal keyboardShouldPersistTaps="always" showsHorizontalScrollIndicator={false} style={{ flexGrow: 0, borderTopWidth: 1, borderTopColor: 'rgba(255,255,255,0.08)' }} contentContainerStyle={{ alignItems: 'center', paddingHorizontal: 8, paddingVertical: 5, gap: 6 }}>
      <Pressable accessibilityRole="button" accessibilityLabel="Control modifier" accessibilityState={{ selected: ctrl }} onPress={() => setCtrl(!ctrl)} style={[keyStyle, ctrl && { backgroundColor: '#5B9CF6' }]}><Text style={[keyText, ctrl && { color: '#1E1E21' }]}>Ctrl</Text></Pressable>
      {keys.map(key => <Pressable key={key.label} accessibilityRole="button" accessibilityLabel={key.label} onPress={() => { if (id !== null) remote.terminalInput(id, key.data).catch(() => {}); setCtrl(false); }} style={keyStyle}><Text style={keyText}>{key.label}</Text></Pressable>)}
    </ScrollView>
  </View>;
}

const keyStyle = { minWidth: 50, height: 42, borderRadius: 8, paddingHorizontal: 12, backgroundColor: '#303036', alignItems: 'center' as const, justifyContent: 'center' as const };
const keyText = { color: '#ECECEF', fontFamily: 'JetBrainsMono' as const, fontSize: 13 };
