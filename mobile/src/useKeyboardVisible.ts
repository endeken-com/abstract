import { useEffect, useState } from 'react';
import { Dimensions, Keyboard, Platform } from 'react-native';

export function useKeyboardVisible() {
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    const show = Keyboard.addListener(Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow', () => setVisible(true));
    const hide = Keyboard.addListener(Platform.OS === 'ios' ? 'keyboardWillHide' : 'keyboardDidHide', () => setVisible(false));
    return () => { show.remove(); hide.remove(); };
  }, []);
  return visible;
}

export function useKeyboardHeight() {
  const [height, setHeight] = useState(0);
  useEffect(() => {
    const update = (event: { endCoordinates: { screenY: number; height: number } }) => {
      const frame = event.endCoordinates;
      const screenHeight = Dimensions.get('screen').height;
      // A floating iPad keyboard does not cover the composer at the screen edge.
      setHeight(frame.screenY + frame.height >= screenHeight - 2 ? Math.max(0, screenHeight - frame.screenY) : 0);
    };
    const show = Keyboard.addListener(Platform.OS === 'ios' ? 'keyboardWillChangeFrame' : 'keyboardDidShow', update);
    const hide = Keyboard.addListener(Platform.OS === 'ios' ? 'keyboardWillHide' : 'keyboardDidHide', () => setHeight(0));
    return () => { show.remove(); hide.remove(); };
  }, []);
  return height;
}
