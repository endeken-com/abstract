import React from 'react';
import { Image, StyleSheet, Text, View } from 'react-native';
import { SymbolView } from 'expo-symbols';
import { imageUri, materialSymbol, tileFor, type ProjectMark } from './projectIcons';

// A project's icon at chat-row size, as the Mac's sidebar shows it: its
// uploaded image (the bytes its Mac sent), else its symbol or initial on its colour.
export function ProjectIcon({ mark, size = 20 }: { mark: ProjectMark; size?: number }) {
  const uri = imageUri(mark.imageData);
  if (uri) return <Image source={{ uri }} style={{ width: size, height: size, borderRadius: 4 }} resizeMode="cover" accessibilityIgnoresInvertColors />;
  const tile = tileFor(mark);
  const glyph = Math.round(size * 0.44);
  return <View style={[styles.tile, { width: size, height: size, backgroundColor: tile.background }]}>
    {tile.symbol
      ? <SymbolView name={{ ios: tile.symbol, android: materialSymbol(tile.symbol), web: materialSymbol(tile.symbol) } as any} size={glyph} tintColor={tile.foreground} style={{ width: glyph, height: glyph }} />
      : <Text style={[styles.initial, { color: tile.foreground, fontSize: Math.round(size * 0.46) }]}>{tile.initial}</Text>}
  </View>;
}

const styles = StyleSheet.create({
  tile: { borderRadius: 5, alignItems: 'center', justifyContent: 'center' },
  initial: { fontFamily: 'Inter', fontWeight: '600' },
});
