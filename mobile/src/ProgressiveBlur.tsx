import React from 'react';
import { Platform, StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import MaskedView from '@react-native-masked-view/masked-view';
import { BlurView } from 'expo-blur';
import { LinearGradient } from 'expo-linear-gradient';

type Props = {
  edge: 'top' | 'bottom';
  style?: StyleProp<ViewStyle>;
  blurTarget?: React.RefObject<View | null>;
  surfaceColor?: string;
};

/** One surface color at either edge; only blur visibility tapers into content. */
export function ProgressiveBlur({ edge, style, blurTarget, surfaceColor = '#1E1E21' }: Props) {
  const top = edge === 'top';
  const mask = top
    ? (['black', 'black', 'rgba(0,0,0,0.85)', 'rgba(0,0,0,0.55)', 'rgba(0,0,0,0.25)', 'transparent'] as const)
    : (['transparent', 'rgba(0,0,0,0.35)', 'rgba(0,0,0,0.75)', 'black', 'black'] as const);
  const locations = top ? ([0, 0.55, 0.66, 0.77, 0.88, 1] as const) : ([0, 0.035, 0.08, 0.12, 1] as const);
  return <View pointerEvents="none" style={[styles.fill, style]}>
    <MaskedView style={styles.fill} maskElement={<LinearGradient colors={mask} locations={locations} style={styles.fill} />}>
      <BlurView intensity={85} tint="systemChromeMaterialDark" blurTarget={blurTarget} blurMethod={Platform.OS === 'android' ? 'dimezisBlurViewSdk31Plus' : undefined} style={styles.fill} />
      <View style={[styles.fill, { backgroundColor: surfaceColor, opacity: top ? 0.72 : 1 }]} />
    </MaskedView>
  </View>;
}

const styles = StyleSheet.create({ fill: { ...StyleSheet.absoluteFillObject } });
