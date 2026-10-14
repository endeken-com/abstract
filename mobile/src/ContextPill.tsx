import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { BranchIcon } from './PullRequestIcon';
import { contextSymbols, type ChatContext } from './chatContext';

const ink = '#ECECEF', tertiary = '#75757E', raised = '#2B2B30';

// The pill above the reply box. It is as wide as its icon, caption and name, and shrinks (cutting the name in the middle) only when the PR and changes pills beside it need the room.
export function ContextPill({ context, onPress }: { context: ChatContext; onPress?: () => void }) {
  const tint = context.icon === 'branch' || context.icon === 'worktree' ? ink : tertiary;
  return <Pressable accessibilityRole="button" accessibilityLabel={context.accessibilityLabel} onPress={onPress} style={contextPillStyles.pill}>
    {context.icon === 'branch' ? <BranchIcon size={15} color={tint} /> : <SymbolView name={contextSymbols[context.icon] as any} size={15} tintColor={tint} style={{ width: 15, height: 15 }} />}
    <View style={contextPillStyles.text}><Text style={contextPillStyles.caption}>{context.caption}</Text><Text style={contextPillStyles.name} numberOfLines={1} ellipsizeMode="middle">{context.label}</Text></View>
  </Pressable>;
}

export const contextPillStyles = StyleSheet.create({
  pill: { flexShrink: 1, minWidth: 0, height: 32, flexDirection: 'row', alignItems: 'center', gap: 7, paddingHorizontal: 8, borderRadius: 16, backgroundColor: raised, borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(255,255,255,0.16)' },
  text: { flexShrink: 1, minWidth: 0, justifyContent: 'center' },
  caption: { color: tertiary, fontFamily: 'Inter', fontSize: 9, fontWeight: '600', letterSpacing: 0.5, lineHeight: 11 },
  name: { color: ink, fontFamily: 'Inter', fontSize: 12, fontWeight: '600', lineHeight: 15 },
});
