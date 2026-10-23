import React, { useRef, useState } from 'react';
import { Modal, Platform, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { MenuView as SystemMenuView, type MenuAction, type MenuComponentProps } from '@react-native-menu/menu';
import { SymbolView } from 'expo-symbols';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

type Anchor = { x: number; y: number; width: number; height: number };

// UIKit gives every UIMenu the same broad panel. On iPhone, keep the same
// actions but present them in a content-sized popover beside their trigger.
export function CompactMenu({ actions, children, style, title, onPressAction, onOpenMenu, onCloseMenu, hitSlop, testID, ...nativeProps }: MenuComponentProps) {
  const trigger = useRef<View>(null);
  const [anchor, setAnchor] = useState<Anchor | null>(null);
  const [path, setPath] = useState<number[]>([]);
  const { width: screenWidth, height: screenHeight, fontScale } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  if (Platform.OS !== 'ios') {
    return <SystemMenuView actions={actions} title={title} onPressAction={onPressAction} onOpenMenu={onOpenMenu} onCloseMenu={onCloseMenu} style={style} hitSlop={hitSlop} testID={testID} {...nativeProps}>{children}</SystemMenuView>;
  }

  const open = () => trigger.current?.measureInWindow((x, y, width, height) => {
    setPath([]);
    setAnchor({ x, y, width, height });
    onOpenMenu?.();
  });
  const close = () => { setAnchor(null); setPath([]); onCloseMenu?.(); };
  let current = actions;
  let heading = title;
  for (const index of path) {
    const parent = current[index];
    if (!parent?.subactions) break;
    heading = parent.title;
    current = parent.subactions;
  }
  const visible = current.map((action, index) => ({ action, index })).filter(({ action }) => !action.attributes?.hidden);
  const longest = Math.max(0, ...visible.map(({ action }) => Math.max(action.title.length, action.subtitle?.length || 0)));
  const hasSymbols = visible.some(({ action }) => !!action.image || action.state === 'on' || !!action.subactions?.length);
  const fillsWidth = !!StyleSheet.flatten(style)?.flex;
  const menuWidth = Math.min(screenWidth - 28, Math.max(154, Math.ceil(longest * 7.3 * fontScale + (hasSymbols ? 66 : 38))));
  const maxHeight = Math.max(120, screenHeight - insets.top - insets.bottom - 20);
  const estimatedHeight = Math.min(maxHeight, visible.length * 46 + (heading ? 34 : 0) + 8);
  const below = anchor ? screenHeight - insets.bottom - (anchor.y + anchor.height) - 10 : 0;
  const above = anchor ? anchor.y - insets.top - 10 : 0;
  const menuTop = anchor ? Math.max(insets.top + 8, Math.min(screenHeight - insets.bottom - estimatedHeight - 8,
    below >= estimatedHeight || below >= above ? anchor.y + anchor.height + 5 : anchor.y - estimatedHeight - 5)) : 0;
  const menuLeft = anchor ? Math.max(14, Math.min(screenWidth - menuWidth - 14,
    anchor.x + anchor.width / 2 > screenWidth / 2 ? anchor.x + anchor.width - menuWidth : anchor.x)) : 0;

  return <View style={style} collapsable={false}>
    <Pressable ref={trigger} accessibilityRole="button" hitSlop={hitSlop} testID={testID} onPress={open} style={fillsWidth ? styles.fill : undefined}>{children}</Pressable>
    <Modal visible={!!anchor} transparent animationType="fade" presentationStyle="overFullScreen" onRequestClose={close}>
      <View style={styles.overlay} accessibilityViewIsModal>
        <Pressable style={StyleSheet.absoluteFill} accessibilityLabel="Close menu" onPress={close} />
        <View style={[styles.menu, { top: menuTop, left: menuLeft, width: menuWidth, maxHeight: Math.min(maxHeight, screenHeight - insets.bottom - menuTop - 8) }]}>
          {heading ? <View style={styles.heading}><Text numberOfLines={1} style={styles.headingText}>{heading}</Text>{path.length > 0 && <Pressable accessibilityRole="button" accessibilityLabel="Back to menu" onPress={() => setPath(path.slice(0, -1))} style={styles.back}><SymbolView name="chevron.backward" size={13} tintColor="#ECECEF" /></Pressable>}</View> : null}
          <ScrollView keyboardShouldPersistTaps="always" bounces={false} showsVerticalScrollIndicator={false}>
            {visible.map(({ action, index }) => {
              const submenu = !!action.subactions?.length;
              const disabled = !!action.attributes?.disabled;
              const destructive = !!action.attributes?.destructive;
              const color = destructive ? '#FF777B' : disabled ? '#73737C' : '#ECECEF';
              return <Pressable key={action.id || `${action.title}-${index}`} accessibilityRole="menuitem" accessibilityLabel={action.title} accessibilityState={{ disabled, selected: action.state === 'on' }} disabled={disabled} onPress={() => {
                if (submenu) { setPath([...path, index]); return; }
                onPressAction?.({ nativeEvent: { event: action.id || action.title } });
                if (!action.attributes?.keepsMenuPresented) close();
              }} style={({ pressed }) => [styles.item, pressed && styles.pressed]}>
                {action.image ? <SymbolView name={action.image as any} size={17} tintColor={color} style={styles.icon} /> : <View style={styles.icon} />}
                <View style={styles.itemBody}><Text numberOfLines={2} style={[styles.itemText, { color }]}>{action.title}</Text>{action.subtitle && <Text numberOfLines={1} style={styles.subtitle}>{action.subtitle}</Text>}</View>
                {action.state === 'on' ? <SymbolView name="checkmark" size={13} tintColor={color} style={styles.trailing} /> : submenu ? <SymbolView name="chevron.forward" size={12} tintColor="#A4A4AD" style={styles.trailing} /> : null}
              </Pressable>;
            })}
          </ScrollView>
        </View>
      </View>
    </Modal>
  </View>;
}

const styles = StyleSheet.create({
  fill: { flex: 1, minWidth: 0 },
  overlay: { flex: 1 },
  menu: { position: 'absolute', backgroundColor: '#343439', borderRadius: 14, borderWidth: StyleSheet.hairlineWidth, borderColor: '#5A5A62', overflow: 'hidden', shadowColor: '#000', shadowOpacity: 0.35, shadowRadius: 18, shadowOffset: { width: 0, height: 8 } },
  heading: { minHeight: 34, paddingLeft: 14, paddingRight: 5, flexDirection: 'row', alignItems: 'center', borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: 'rgba(255,255,255,0.1)' },
  headingText: { flex: 1, color: '#A4A4AD', fontFamily: 'Inter', fontSize: 11.5, fontWeight: '600' },
  back: { width: 34, height: 34, alignItems: 'center', justifyContent: 'center' },
  item: { minHeight: 46, paddingLeft: 12, paddingRight: 13, flexDirection: 'row', alignItems: 'center', gap: 9, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: 'rgba(255,255,255,0.07)' },
  pressed: { backgroundColor: '#4A4A51' },
  icon: { width: 18, height: 18 },
  itemBody: { flex: 1, minWidth: 0, paddingVertical: 10 },
  itemText: { fontFamily: 'Inter', fontSize: 14 },
  subtitle: { color: '#A4A4AD', fontFamily: 'Inter', fontSize: 11, marginTop: 2 },
  trailing: { width: 13, height: 13 },
});
