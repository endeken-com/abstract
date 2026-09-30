import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { MenuView, type MenuAction } from '@react-native-menu/menu';
import { SymbolView } from 'expo-symbols';

type Choice = { id: string; title: string; selected?: boolean; image?: string };

/** A platform menu anchored to a compact picker, matching Abstract's composer menus. */
export function NativeSelect({ label, value, choices, onSelect, flex = 1, align = 'center', leading }: {
  label: string;
  value: string;
  choices: Choice[];
  onSelect: (id: string) => void;
  flex?: number;
  align?: 'center' | 'left';
  leading?: React.ReactNode;
}) {
  const actions: MenuAction[] = choices.map(choice => ({
    id: choice.id,
    title: choice.title,
    state: choice.selected ? 'on' : 'off',
    image: choice.image,
  }));
  return <MenuView title={label} actions={actions} onPressAction={({ nativeEvent }) => onSelect(nativeEvent.event)} style={{ flex, minWidth: 0 }}>
    <View accessibilityRole="button" accessibilityLabel={`${label}: ${value}`} style={[styles.trigger, align === 'left' && styles.triggerLeft]}>
      {leading}
      <Text numberOfLines={1} style={styles.value}>{value}</Text>
      <SymbolView name={{ ios: 'chevron.down', android: 'keyboard_arrow_down' }} size={11} tintColor="#85858E" style={styles.chevron} />
    </View>
  </MenuView>;
}

const styles = StyleSheet.create({
  trigger: { height: 42, minWidth: 0, paddingHorizontal: 6, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 4 },
  triggerLeft: { justifyContent: 'flex-start' },
  value: { minWidth: 0, flexShrink: 1, color: '#A4A4AD', fontFamily: 'Inter', fontSize: 12.5, fontWeight: '500' },
  chevron: { width: 11, height: 11 },
});
