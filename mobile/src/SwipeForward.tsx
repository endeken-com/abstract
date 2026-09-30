import React, { useMemo, useRef } from 'react';
import { PanResponder, Platform, View, type StyleProp, type ViewStyle } from 'react-native';

/** A deliberate left swipe in a workspace view opens its next full-screen view. */
export function SwipeForward({ children, onSwipe, onBack, enabled = true, style }: { children: React.ReactNode; onSwipe: () => void; onBack?: () => void; enabled?: boolean; style?: StyleProp<ViewStyle> }) {
  const current = useRef({ onSwipe, onBack, enabled });
  current.current = { onSwipe, onBack, enabled };
  const responder = useMemo(() => PanResponder.create({
    onMoveShouldSetPanResponderCapture: (_, gesture) => current.current.enabled && (gesture.dx < -28 || (Platform.OS === 'android' && !!current.current.onBack && gesture.dx > 28)) && Math.abs(gesture.dx) > Math.abs(gesture.dy) * 1.45,
    onPanResponderRelease: (_, gesture) => {
      if (current.current.enabled && gesture.dx < -80 && Math.abs(gesture.dx) > Math.abs(gesture.dy) * 1.35) current.current.onSwipe();
      if (current.current.enabled && Platform.OS === 'android' && current.current.onBack && gesture.dx > 80 && Math.abs(gesture.dx) > Math.abs(gesture.dy) * 1.35) current.current.onBack();
    }
  }), []);
  return <View style={[{ flex: 1 }, style]} {...responder.panHandlers}>{children}</View>;
}
