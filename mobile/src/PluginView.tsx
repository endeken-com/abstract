import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';
import WebView from 'react-native-webview';
import { useHeaderHeight } from '@react-navigation/elements';
import { Buffer } from 'buffer';
import { remote } from './remote';
import { buildPluginDocument, hostMessageJS, invokeEnvelope, pluginMessageArgs, pluginShowingArgs } from './plugins';
import type { PluginPlace } from './types';

const ink = '#ECECEF', muted = '#A4A4AD', bg = '#1E1E21';

export type PluginRoute = {
  hostId: string; pluginId: string; title: string;
  place: PluginPlace; contributionId: string; chatId?: string | null; invoke?: boolean;
};

// One showing of a plugin on the phone: its package, fetched from the Mac,
// in a locked-down web view. Bridge messages run on the Mac, which answers
// with the envelopes to deliver back.
export function PluginView({ route, navigation, height }: { route: PluginRoute; navigation?: any; height?: number }) {
  const { hostId, pluginId, place, contributionId, chatId } = route;
  const mac = remote.client(hostId);
  const plugin = mac.snapshot?.plugins?.find(x => x.id === pluginId);
  const [html, setHtml] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [reloadToken, setReloadToken] = useState(0);
  const web = useRef<WebView>(null);
  const loaded = useRef(false);
  const pushTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const deliver = (messages: string[]) => messages.forEach(m => web.current?.injectJavaScript(hostMessageJS(m)));
  const pushContext = () => {
    if (!loaded.current) return;
    remote.client(hostId).request('pluginContext', pluginShowingArgs(pluginId, place, contributionId, chatId))
      .then(reply => deliver(reply.pluginMessages?.messages || []))
      .catch(() => {});
  };

  useEffect(() => {
    let active = true;
    loaded.current = false;
    setHtml(null); setError(null); setFailed(false);
    remote.client(hostId).request('pluginPackage', { pluginId })
      .then(reply => {
        if (!active) return;
        const pack = reply.pluginPackage?._0 as { entry: string; files: Record<string, string> } | undefined;
        const document = pack && buildPluginDocument(pack.files, pack.entry, b64 => Buffer.from(b64, 'base64').toString('utf8'));
        if (document) setHtml(document); else setError("Its files couldn't be read, so it's off.");
      })
      .catch(reason => { if (active) setError(String(reason?.message || reason)); });
    return () => { active = false; };
  }, [hostId, pluginId, reloadToken]);

  // Live chats move: a fresh snapshot from the Mac pushes one here too.
  useEffect(() => remote.subscribe(() => {
    if (!loaded.current || pushTimer.current) return;
    pushTimer.current = setTimeout(() => { pushTimer.current = null; pushContext(); }, 300);
  }), [hostId, pluginId]);

  if (plugin && !plugin.usable) return <View style={[styles.center, height ? { height } : { flex: 1 }]}>
    <Text style={styles.title}>{plugin.name} is off</Text>
    <Text style={styles.note}>{plugin.problem || 'Turn it on in Plugins to see its screen.'}</Text>
  </View>;
  if (error) return <View style={[styles.center, height ? { height } : { flex: 1 }]}>
    <Text style={styles.title}>Couldn't open this plugin</Text><Text style={styles.note}>{error}</Text>
  </View>;
  if (failed) return <View style={[styles.center, height ? { height } : { flex: 1 }]}>
    <Text style={styles.title}>{plugin?.name || 'This plugin'} stopped working.</Text>
    <Text style={styles.note}>Nothing else in Abstract was affected.</Text>
    <View style={styles.actions}>
      <Pressable accessibilityRole="button" onPress={() => setReloadToken(x => x + 1)} style={styles.primary}><Text style={styles.primaryText}>Reload</Text></Pressable>
      <Pressable accessibilityRole="button" onPress={() => mac.request('setPluginEnabled', { pluginId, enabled: false, transcriptProjectKeys: null }).catch(() => {})} style={styles.secondary}><Text style={styles.secondaryText}>Turn Off</Text></Pressable>
    </View>
  </View>;
  if (!html) return <View style={[styles.center, height ? { height } : { flex: 1 }]}><ActivityIndicator color={muted} /></View>;

  return <WebView key={reloadToken} ref={web} source={{ html, baseUrl: 'about:blank' }}
    originWhitelist={['about:blank']} javaScriptEnabled domStorageEnabled={false}
    setSupportMultipleWindows={false} allowsInlineMediaPlayback={false}
    onShouldStartLoadWithRequest={request => request.url === 'about:blank'}
    style={height ? { height, backgroundColor: bg } : { flex: 1, backgroundColor: bg }}
    onLoadEnd={() => {
      loaded.current = true;
      pushContext();
      if (route.invoke) web.current?.injectJavaScript(hostMessageJS(invokeEnvelope(place, contributionId, chatId)));
    }}
    onError={() => setFailed(true)}
    onMessage={event => {
      const text = event.nativeEvent.data;
      remote.client(hostId).request('pluginMessage', pluginMessageArgs(pluginId, text, place, contributionId, chatId))
        .then(reply => {
          const result = reply.pluginMessages as { messages: string[]; openChatId?: string | null } | undefined;
          if (result) deliver(result.messages || []);
          if (result?.openChatId) navigation?.navigate('Chat', { hostId, sessionId: result.openChatId });
        })
        .catch(() => setFailed(true));
    }} />;
}

export function PluginScreen({ route, navigation }: any) {
  const params = route.params as PluginRoute;
  const headerHeight = useHeaderHeight();
  useEffect(() => { navigation.setOptions({ title: params.title }); }, [navigation, params.title]);
  return <View style={{ flex: 1, backgroundColor: bg, paddingTop: headerHeight }}><PluginView route={params} navigation={navigation} /></View>;
}

const styles = StyleSheet.create({
  center: { alignItems: 'center', justifyContent: 'center', padding: 24, gap: 8, backgroundColor: bg },
  title: { color: ink, fontFamily: 'Inter', fontSize: 15, fontWeight: '600', textAlign: 'center' },
  note: { color: muted, fontFamily: 'Inter', fontSize: 13, lineHeight: 19, textAlign: 'center' },
  actions: { flexDirection: 'row', gap: 8, marginTop: 6 },
  primary: { backgroundColor: ink, borderRadius: 8, paddingHorizontal: 14, paddingVertical: 10 },
  primaryText: { color: bg, fontFamily: 'Inter', fontSize: 13, fontWeight: '600' },
  secondary: { backgroundColor: '#303036', borderRadius: 8, paddingHorizontal: 14, paddingVertical: 10 },
  secondaryText: { color: ink, fontFamily: 'Inter', fontSize: 13, fontWeight: '600' },
});
