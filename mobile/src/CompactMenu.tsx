import React, { useEffect, useRef, useState } from 'react';
import { Animated, Modal, Platform, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { MenuView as SystemMenuView, type MenuAction, type MenuComponentProps } from '@react-native-menu/menu';
import { Host, Rectangle } from '@expo/ui/swift-ui';
import { foregroundStyle, frame, glassEffect } from '@expo/ui/swift-ui/modifiers';
import { BlurView } from 'expo-blur';
import { SymbolView } from 'expo-symbols';
import * as Haptics from 'expo-haptics';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

type Anchor = { x: number; y: number; width: number; height: number };
type Size = { width: number; height: number };

const liquidGlass = Platform.OS === 'ios' && parseInt(String(Platform.Version), 10) >= 26;
const radius = liquidGlass ? 24 : 13;
const edge = 12;
const minWidth = 160;

// UIKit sizes every UIMenu to the same broad panel. On iPhone, keep the system
// look (glass, SF text, row layout) but size the panel to its own actions.
export function CompactMenu({ actions, children, style, title, onPressAction, onOpenMenu, onCloseMenu, hitSlop, testID, ...nativeProps }: MenuComponentProps) {
  const trigger = useRef<View>(null);
  const [anchor, setAnchor] = useState<Anchor | null>(null);
  const [path, setPath] = useState<number[]>([]);
  const [size, setSize] = useState<Size | null>(null);
  const appear = useRef(new Animated.Value(0)).current;
  const { width: screenWidth, height: screenHeight, fontScale } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  useEffect(() => { setSize(null); }, [fontScale]);
  useEffect(() => {
    if (!size || !anchor) return;
    Animated.spring(appear, { toValue: 1, useNativeDriver: true, damping: 22, stiffness: 320, mass: 0.8 }).start();
  }, [size, anchor, appear]);
  if (Platform.OS !== 'ios') {
    return <SystemMenuView actions={actions} title={title} onPressAction={onPressAction} onOpenMenu={onOpenMenu} onCloseMenu={onCloseMenu} style={style} hitSlop={hitSlop} testID={testID} {...nativeProps}>{children}</SystemMenuView>;
  }

  const open = () => trigger.current?.measureInWindow((x, y, width, height) => {
    setPath([]);
    setSize(null);
    setAnchor({ x, y, width, height });
    Haptics.selectionAsync().catch(() => {});
    onOpenMenu?.();
  });
  const go = (next: number[]) => { setSize(null); setPath(next); };
  const close = () => { setAnchor(null); setPath([]); setSize(null); onCloseMenu?.(); };
  let current: MenuAction[] = actions;
  let heading = title;
  for (const index of path) {
    const parent = current[index];
    if (!parent?.subactions) break;
    heading = parent.title;
    current = parent.subactions;
  }
  const visible = current.map((action, index) => ({ action, index })).filter(({ action }) => !action.attributes?.hidden);
  const checks = visible.some(({ action }) => action.state === 'on');
  const maxWidth = screenWidth - edge * 2;
  const room = screenHeight - insets.top - insets.bottom - edge * 2;

  // Place the measured panel beside its trigger: below when it fits (or has more
  // room), aligned to whichever trigger edge is nearer the screen edge.
  let place: { top: number; left: number; height: number; origin: string } | null = null;
  if (anchor && size) {
    const width = Math.min(maxWidth, Math.max(minWidth, size.width));
    const height = Math.min(room, size.height);
    const below = screenHeight - insets.bottom - edge - (anchor.y + anchor.height + 6);
    const above = anchor.y - 6 - insets.top - edge;
    const down = below >= height || below >= above;
    const top = Math.max(insets.top + edge, Math.min(screenHeight - insets.bottom - edge - height, down ? anchor.y + anchor.height + 6 : anchor.y - 6 - height));
    const right = anchor.x + anchor.width / 2 > screenWidth / 2;
    const left = Math.max(edge, Math.min(screenWidth - edge - width, right ? anchor.x + anchor.width - width : anchor.x));
    place = { top, left, height, origin: `${right ? 'right' : 'left'} ${down ? 'top' : 'bottom'}` };
  }
  const childLabel = React.isValidElement(children) ? (children.props as { accessibilityLabel?: string }).accessibilityLabel : undefined;
  const fillsWidth = !!StyleSheet.flatten(style)?.flex;

  const rows = <>
    {heading ? <View style={styles.heading}>
      {path.length > 0 && <Pressable accessibilityRole="button" accessibilityLabel="Back to menu" hitSlop={8} onPress={() => go(path.slice(0, -1))} style={styles.back}><SymbolView name="chevron.backward" size={15} weight="semibold" tintColor={colors.secondary} /></Pressable>}
      <Text numberOfLines={1} style={styles.headingText}>{heading}</Text>
    </View> : null}
    {visible.map(({ action, index }) => {
      const submenu = !!action.subactions?.length;
      const disabled = !!action.attributes?.disabled;
      const destructive = !!action.attributes?.destructive;
      const color = disabled ? colors.disabled : destructive ? colors.destructive : colors.label;
      return <Pressable key={action.id || `${action.title}-${index}`} accessibilityRole="menuitem" accessibilityLabel={action.title} accessibilityHint={action.subtitle} accessibilityState={{ disabled, selected: action.state === 'on' }} disabled={disabled} onPress={() => {
        if (submenu) { go([...path, index]); return; }
        Haptics.selectionAsync().catch(() => {});
        onPressAction?.({ nativeEvent: { event: action.id || action.title } });
        if (!action.attributes?.keepsMenuPresented) close();
      }} style={({ pressed }) => [styles.item, pressed && styles.pressed]}>
        {checks && <View style={styles.check}>{action.state === 'on' && <SymbolView name="checkmark" size={15} weight="semibold" tintColor={color} />}</View>}
        <View style={styles.itemBody}>
          <Text numberOfLines={2} style={[styles.itemText, { color }]}>{action.title}</Text>
          {action.subtitle ? <Text numberOfLines={2} style={styles.subtitle}>{action.subtitle}</Text> : null}
        </View>
        {submenu ? <SymbolView name="chevron.forward" size={14} weight="semibold" tintColor={colors.secondary} style={styles.trailing} />
          : action.image ? <SymbolView name={action.image as any} size={18} tintColor={color} style={styles.trailing} /> : null}
      </Pressable>;
    })}
  </>;

  return <View style={style} collapsable={false}>
    <Pressable ref={trigger} accessibilityRole="button" accessibilityLabel={childLabel || title || 'Menu'} hitSlop={hitSlop} testID={testID} onPress={open} style={fillsWidth ? styles.fill : undefined}>{children}</Pressable>
    <Modal visible={!!anchor} transparent animationType="none" presentationStyle="overFullScreen" onRequestClose={close}>
      <View style={styles.overlay} accessibilityViewIsModal>
        <Pressable style={StyleSheet.absoluteFill} accessibilityLabel="Close menu" onPress={close} />
        {!place ? <View pointerEvents="none" style={[styles.measure, { maxWidth }]} onLayout={(event) => {
          const { width, height } = event.nativeEvent.layout;
          appear.setValue(0);
          setSize({ width: Math.ceil(width), height: Math.ceil(height) });
        }}>{rows}</View> : null}
        {place ? <Animated.View style={[styles.menu, {
          top: place.top, left: place.left, width: Math.min(maxWidth, Math.max(minWidth, size!.width)), height: place.height,
          transformOrigin: place.origin, opacity: appear,
          transform: [{ scale: appear.interpolate({ inputRange: [0, 1], outputRange: [0.86, 1] }) }],
        }]}>
          {liquidGlass
            ? <Host style={StyleSheet.absoluteFill} colorScheme="dark" ignoreSafeArea="all"><Rectangle modifiers={[foregroundStyle('clear'), frame({ maxWidth: Infinity, maxHeight: Infinity }), glassEffect({ glass: { variant: 'regular' }, shape: 'roundedRectangle', cornerRadius: radius })]} /></Host>
            : <BlurView intensity={100} tint="systemMaterialDark" style={StyleSheet.absoluteFill} />}
          <ScrollView keyboardShouldPersistTaps="always" bounces={false} scrollEnabled={size!.height > place.height} showsVerticalScrollIndicator={false} contentContainerStyle={styles.content}>{rows}</ScrollView>
        </Animated.View> : null}
      </View>
    </Modal>
  </View>;
}

const colors = {
  label: '#FFFFFF',
  secondary: 'rgba(235,235,245,0.6)',
  disabled: 'rgba(235,235,245,0.3)',
  destructive: '#FF453A',
};

const styles = StyleSheet.create({
  fill: { flex: 1, minWidth: 0 },
  overlay: { flex: 1 },
  measure: { position: 'absolute', top: 0, left: 0, opacity: 0, padding: 6 },
  menu: { position: 'absolute', borderRadius: radius, borderCurve: 'continuous', overflow: 'hidden', shadowColor: '#000', shadowOpacity: liquidGlass ? 0 : 0.3, shadowRadius: 24, shadowOffset: { width: 0, height: 10 } },
  content: { padding: 6 },
  heading: { minHeight: 32, paddingHorizontal: 12, flexDirection: 'row', alignItems: 'center', gap: 8 },
  headingText: { flexShrink: 1, color: colors.secondary, fontSize: 13, fontWeight: '600' },
  back: { width: 20, height: 20, alignItems: 'center', justifyContent: 'center' },
  item: { minHeight: 44, paddingHorizontal: 12, flexDirection: 'row', alignItems: 'center', gap: 10, borderRadius: radius - 6, borderCurve: 'continuous' },
  pressed: { backgroundColor: 'rgba(255,255,255,0.14)' },
  check: { width: 16, alignItems: 'center' },
  itemBody: { flexGrow: 1, flexShrink: 1, paddingVertical: 11 },
  itemText: { fontSize: 17 },
  subtitle: { color: colors.secondary, fontSize: 13, marginTop: 2 },
  trailing: { width: 20, height: 20, marginLeft: 6 },
});
