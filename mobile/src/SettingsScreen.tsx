import React, { useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, Alert, Platform, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { useHeaderHeight } from '@react-navigation/elements';
import { MenuView } from '@react-native-menu/menu';
import { SymbolView } from 'expo-symbols';
import * as Haptics from 'expo-haptics';
import { KeyboardAwareScrollView } from './KeyboardAwareScrollView';
import { remote } from './remote';
import { phoneHostName } from './secure';
import type { Device } from './types';

const ink = '#ECECEF', muted = '#A4A4AD', tertiary = '#75757E';
const bg = '#1E1E21', panel = '#252529', raised = '#2B2B30';
const border = 'rgba(255,255,255,0.075)';

function useRemote() {
  const [, rerender] = useState(0);
  useEffect(() => remote.subscribe(() => rerender(value => value + 1)), []);
  return remote;
}

function Icon({ name, size = 18, color = muted }: { name: string; size?: number; color?: string }) {
  const androidNames: Record<string, string> = { iphone: 'smartphone', laptopcomputer: 'laptop_mac', 'chevron.right': 'chevron_right', 'chevron.down': 'keyboard_arrow_down', checkmark: 'check', ellipsis: 'more_horiz', 'exclamationmark.circle': 'error_outline' };
  return <SymbolView name={{ ios: name, android: androidNames[name] || name } as any} size={size} tintColor={color} />;
}

function Group({ title, caption, children }: { title: string; caption?: string; children: React.ReactNode }) {
  return <View style={styles.group}>
    <Text style={styles.groupTitle}>{title}</Text>
    {caption ? <Text style={styles.caption}>{caption}</Text> : null}
    <View style={styles.card}>{children}</View>
  </View>;
}

function Action({ title, onPress, disabled = false }: { title: string; onPress: () => void; disabled?: boolean }) {
  return <Pressable accessibilityRole="button" accessibilityLabel={title} accessibilityState={{ disabled }} disabled={disabled} onPress={() => { Haptics.selectionAsync().catch(() => {}); onPress(); }} style={({ pressed }) => [styles.action, disabled && styles.disabled, pressed && styles.pressed]}>
    <Text style={styles.actionLabel}>{title}</Text><Icon name="chevron.right" size={13} />
  </Pressable>;
}

export function SettingsScreen() {
  const state = useRemote();
  const headerHeight = useHeaderHeight();
  const name = useMemo(phoneHostName, []);
  const [invitation, setInvitation] = useState('');
  const [address, setAddress] = useState('');
  const [advanced, setAdvanced] = useState(false);
  const nearby = state.nearby.filter(mac => !state.devices.some(device => device.peer.id === mac.id));
  const active = state.active;
  const connect = (endpoint: string, device?: Device) => {
    Haptics.selectionAsync().catch(() => {});
    state.connect(endpoint.trim(), device).catch(() => {});
  };
  const forget = (device: Device) => Alert.alert('Forget this Mac?', device.peer.name, [
    { text: 'Cancel', style: 'cancel' },
    { text: 'Forget', style: 'destructive', onPress: () => state.forget(device.peer.id).catch(error => Alert.alert('Abstract', String(error))) }
  ]);
  const status = state.status === 'online' ? 'Connected' : state.status === 'connecting' ? 'Connecting…' : state.status === 'pairing' ? 'Pairing…' : 'Not connected';

  return <KeyboardAwareScrollView style={styles.page} contentContainerStyle={[styles.content, { paddingTop: headerHeight + 24 }]} keyboardShouldPersistTaps="handled">
    <View style={styles.intro}><Text style={styles.title}>Settings</Text><Text style={styles.lead}>Manage your phone and Mac connections.</Text></View>

    <Group title="THIS PHONE">
      <View style={styles.identityRow}>
        <View style={styles.largeIcon}><Icon name={Platform.OS === 'ios' ? 'iphone' : 'smartphone'} size={25} color={ink} /></View>
        <View style={styles.flex}><Text style={styles.name} numberOfLines={1}>{name}</Text><Text style={styles.detail}>Shown to Macs when pairing</Text></View>
      </View>
    </Group>

    <Group title="CONNECTION">
      <View style={styles.identityRow}>
        <View style={styles.largeIcon}><Icon name="laptopcomputer" size={25} color={ink} /></View>
        <View style={styles.flex}><Text style={styles.name} numberOfLines={1}>{active?.peer.name || 'No Mac connected'}</Text><Text style={styles.detail}>{status}</Text></View>
        {state.status === 'connecting' || state.status === 'pairing' ? <ActivityIndicator size="small" color={muted} /> : <View style={[styles.dot, state.status !== 'online' && styles.dotOffline]} />}
      </View>
      {active ? <Action title={state.status === 'online' ? 'Disconnect' : 'Reconnect'} onPress={() => state.status === 'online' ? state.disconnectFromMac() : connect(state.nearby.find(mac => mac.id === active.peer.id)?.address || active.address, active)} /> : null}
    </Group>
    {state.error ? <View style={styles.error}><Icon name="exclamationmark.circle" size={17} color="#EF8582" /><Text style={styles.errorText}>{state.error}</Text></View> : null}
    {state.pairingCode ? <View style={styles.pairing}><Text style={styles.name}>Approve on your Mac</Text><Text style={styles.detail}>Check that this code matches the one in Abstract.</Text><Text style={styles.code}>{state.pairingCode}</Text></View> : null}

    <Group title="PAIRED MACS">
      {state.devices.length ? state.devices.map((device, index) => <View key={device.peer.id} style={index > 0 && styles.divider}>
        <View style={styles.deviceRow}>
          <Pressable accessibilityRole="button" accessibilityLabel={`Connect to ${device.peer.name}`} onPress={() => connect(state.nearby.find(mac => mac.id === device.peer.id)?.address || device.address, device)} style={({ pressed }) => [styles.deviceMain, pressed && styles.pressed]}>
            <Icon name="laptopcomputer" size={18} /><View style={styles.flex}><Text style={styles.name} numberOfLines={1}>{device.peer.name}</Text><Text style={styles.detail} numberOfLines={1}>{state.status === 'online' && active?.peer.id === device.peer.id ? 'Connected now' : state.nearby.some(mac => mac.id === device.peer.id) ? 'Nearby · Tap to connect' : 'Tap to connect'}</Text></View>
            <Icon name={state.status === 'online' && active?.peer.id === device.peer.id ? 'checkmark' : 'chevron.right'} size={13} color={state.status === 'online' && active?.peer.id === device.peer.id ? '#8EDBAD' : tertiary} />
          </Pressable>
          <MenuView actions={[{ id: 'forget', title: 'Forget Mac', image: Platform.OS === 'ios' ? 'trash' : undefined, attributes: { destructive: true } }]} onPressAction={() => forget(device)}><View accessibilityLabel={`More options for ${device.peer.name}`} style={styles.more}><Icon name="ellipsis" size={17} /></View></MenuView>
        </View>
      </View>) : <Text style={styles.empty}>Macs you pair will appear here.</Text>}
    </Group>

    <Group title="NEARBY MACS">
      {nearby.length ? nearby.map((mac, index) => <Pressable key={mac.id} accessibilityRole="button" accessibilityLabel={`Pair with ${mac.name}`} onPress={() => connect(mac.address)} style={({ pressed }) => [styles.deviceMain, index > 0 && styles.divider, pressed && styles.pressed]}>
        <Icon name="laptopcomputer" size={18} /><View style={styles.flex}><Text style={styles.name}>{mac.name}</Text><Text style={styles.detail}>Tap to pair</Text></View><Icon name="chevron.right" size={13} color={tertiary} />
      </Pressable>) : <Text style={styles.empty}>Searching your local network. Open Abstract on a Mac and enable mobile sharing in its Settings.</Text>}
    </Group>

    <Group title="CONNECT OVER THE INTERNET" caption="Copy an invitation from Abstract on your Mac in Settings → Devices.">
      <TextInput style={styles.input} value={invitation} onChangeText={setInvitation} placeholder="Paste an invitation" placeholderTextColor={tertiary} autoCapitalize="none" autoCorrect={false} keyboardType="url" />
      <Action title="Pair with Mac" disabled={!invitation.trim()} onPress={() => connect(invitation)} />
    </Group>

    <View style={styles.group}>
      <Pressable accessibilityRole="button" accessibilityState={{ expanded: advanced }} onPress={() => { Haptics.selectionAsync().catch(() => {}); setAdvanced(!advanced); }} style={styles.disclosure}><Text style={styles.groupTitle}>CONNECT BY ADDRESS</Text><Icon name={advanced ? 'chevron.down' : 'chevron.right'} size={13} /></Pressable>
      {advanced ? <><Text style={styles.caption}>For a Mac on your local network or VPN.</Text><View style={styles.card}><TextInput style={styles.input} value={address} onChangeText={setAddress} placeholder="mac.example.com:52000" placeholderTextColor={tertiary} autoCapitalize="none" autoCorrect={false} keyboardType="url" /><Action title="Connect or pair" disabled={!address.trim()} onPress={() => connect(address, state.devices.find(device => device.address === address.trim()))} /></View></> : null}
    </View>
  </KeyboardAwareScrollView>;
}

const styles = StyleSheet.create({
  page: { flex: 1, backgroundColor: bg },
  content: { paddingHorizontal: 18, paddingBottom: 48, gap: 26 },
  intro: { gap: 5, marginBottom: 3 },
  title: { color: ink, fontFamily: 'Inter', fontSize: 27, fontWeight: '600' },
  lead: { color: muted, fontFamily: 'Inter', fontSize: 14, lineHeight: 21 },
  group: { gap: 9 },
  groupTitle: { color: tertiary, fontFamily: 'Inter', fontSize: 11, fontWeight: '700', letterSpacing: 0.8, marginLeft: 3 },
  caption: { color: muted, fontFamily: 'Inter', fontSize: 12.5, lineHeight: 18, marginHorizontal: 3, marginBottom: 2 },
  card: { backgroundColor: panel, borderRadius: 14, borderWidth: StyleSheet.hairlineWidth, borderColor: border, overflow: 'hidden' },
  identityRow: { flexDirection: 'row', alignItems: 'center', gap: 13, minHeight: 76, paddingHorizontal: 15, paddingVertical: 13 },
  largeIcon: { width: 44, height: 44, borderRadius: 12, backgroundColor: raised, alignItems: 'center', justifyContent: 'center' },
  flex: { flex: 1, minWidth: 0 },
  name: { color: ink, fontFamily: 'Inter', fontSize: 15, fontWeight: '600' },
  detail: { color: muted, fontFamily: 'Inter', fontSize: 12.5, lineHeight: 18, marginTop: 3 },
  dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#4CC38A' },
  dotOffline: { backgroundColor: tertiary },
  action: { minHeight: 46, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 15 },
  actionLabel: { color: ink, fontFamily: 'Inter', fontSize: 14, fontWeight: '500' },
  disabled: { opacity: 0.4 },
  pressed: { backgroundColor: raised },
  deviceRow: { flexDirection: 'row', alignItems: 'center' },
  deviceMain: { minHeight: 66, flex: 1, flexDirection: 'row', alignItems: 'center', gap: 13, paddingLeft: 16, paddingRight: 12, paddingVertical: 11 },
  more: { width: 45, minHeight: 58, alignItems: 'center', justifyContent: 'center' },
  divider: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: border },
  empty: { color: muted, fontFamily: 'Inter', fontSize: 13, lineHeight: 19, paddingHorizontal: 16, paddingVertical: 18 },
  input: { color: ink, fontFamily: 'Inter', fontSize: 14.5, minHeight: 50, paddingHorizontal: 15, paddingVertical: 12 },
  disclosure: { minHeight: 36, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 3 },
  error: { backgroundColor: '#3D292B', borderRadius: 12, padding: 14, flexDirection: 'row', alignItems: 'flex-start', gap: 9 },
  errorText: { color: '#F1ACAA', fontFamily: 'Inter', fontSize: 13, lineHeight: 19, flex: 1 },
  pairing: { backgroundColor: raised, borderRadius: 14, padding: 17, gap: 3 },
  code: { color: ink, fontFamily: 'JetBrainsMonoMedium', fontSize: 30, letterSpacing: 2, marginTop: 11 }
});
