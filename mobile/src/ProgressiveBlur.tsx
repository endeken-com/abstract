import React from 'react';
import { Platform, StyleSheet, View, type ViewStyle } from 'react-native';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import { LinearGradient } from 'expo-linear-gradient';

type Props = {
  edge: 'top' | 'bottom';
  style?: ViewStyle;
  blurTarget?: React.RefObject<View | null>;
};

/** Native backdrop blur whose opacity tapers into the transcript. */
export function ProgressiveBlur({ edge, style, blurTarget }: Props) {
  const top = edge === 'top';
  const mask = top
    ? (['black', 'black', 'rgba(0,0,0,0.9)', 'rgba(0,0,0,0.65)', 'rgba(0,0,0,0.3)', 'transparent'] as const)
    : (['transparent', 'rgba(0,0,0,0.18)', 'rgba(0,0,0,0.48)', 'rgba(0,0,0,0.8)', 'rgba(0,0,0,0.98)', 'black'] as const);
  const shade = top
    ? (['rgba(30,30,33,0.98)', 'rgba(30,30,33,0.98)', 'rgba(30,30,33,0.87)', 'rgba(30,30,33,0.58)', 'rgba(30,30,33,0.22)', 'rgba(30,30,33,0)'] as const)
    : (['rgba(30,30,33,0)', 'rgba(30,30,33,0.14)', 'rgba(30,30,33,0.4)', 'rgba(30,30,33,0.72)', 'rgba(30,30,33,0.92)', 'rgba(30,30,33,0.98)'] as const);
  const locations = top ? ([0, 0.7, 0.78, 0.86, 0.93, 1] as const) : ([0, 0.2, 0.4, 0.6, 0.8, 1] as const);
  return <View pointerEvents="none" style={[styles.fill, style]}>
    <MaskedView style={styles.fill} maskElement={<LinearGradient colors={mask} locations={locations} style={styles.fill} />}>
      <BlurView intensity={85} tint="systemChromeMaterialDark" blurTarget={blurTarget} blurMethod={Platform.OS === 'android' ? 'dimezisBlurViewSdk31Plus' : undefined} style={styles.fill} />
    </MaskedView>
    <LinearGradient colors={shade} locations={locations} style={styles.fill} />
  </View>;
}

const styles = StyleSheet.create({ fill: { ...StyleSheet.absoluteFillObject } });
