import React, { useEffect, useRef, useState } from 'react';
import { Animated, Easing, StyleSheet, Text, View } from 'react-native';
import MaskedView from '@react-native-masked-view/masked-view';
import { LinearGradient } from 'expo-linear-gradient';
import { ProviderLogo } from './ProviderLogo';

export function ScrollingTitle({ title, provider, width }: { title: string; provider: string; width: number }) {
  const [textWidth, setTextWidth] = useState(0);
  const offset = useRef(new Animated.Value(0)).current;
  const overflow = Math.max(0, textWidth - width + 2);
  useEffect(() => {
    offset.setValue(0);
    if (overflow <= 0) return;
    const animation = Animated.loop(Animated.sequence([
      Animated.delay(1100),
      Animated.timing(offset, { toValue: -overflow, duration: Math.max(2800, overflow * 28), easing: Easing.linear, useNativeDriver: true }),
      Animated.delay(900),
      Animated.timing(offset, { toValue: 0, duration: Math.max(2800, overflow * 28), easing: Easing.linear, useNativeDriver: true }),
    ]));
    animation.start();
    return () => animation.stop();
  }, [title, overflow, offset]);
  return <View accessibilityLabel={title} style={styles.row}>
    <ProviderLogo provider={provider} size={14} />
    <MaskedView style={[styles.viewport, { width }]} maskElement={overflow > 0 ? <LinearGradient colors={['transparent', 'black', 'black', 'transparent']} locations={[0, 0.09, 0.91, 1]} start={{ x: 0, y: 0 }} end={{ x: 1, y: 0 }} style={StyleSheet.absoluteFill} /> : <View style={styles.solidMask} />}>
      <Animated.View style={[styles.moving, { transform: [{ translateX: offset }] }]}>
        <Text onTextLayout={event => setTextWidth(Math.ceil(event.nativeEvent.lines[0]?.width || 0))} numberOfLines={1} style={[styles.title, { width: Math.max(width * 3, title.length * 14) }]}>{title}</Text>
      </Animated.View>
    </MaskedView>
  </View>;
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  viewport: { height: 28, justifyContent: 'center', overflow: 'hidden' },
  moving: { position: 'absolute', left: 0, top: 4, flexDirection: 'row', alignItems: 'center' },
  solidMask: { flex: 1, backgroundColor: 'black' },
  title: { color: '#ECECEF', fontFamily: 'Inter', fontSize: 14, fontWeight: '600' },
});
