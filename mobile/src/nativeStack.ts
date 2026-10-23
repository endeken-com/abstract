import { Platform } from 'react-native';
import { requireNativeModule } from 'expo-modules-core';

// Back to the first screen the way a back swipe goes. Resolves false when the
// native stack couldn't do it, so the caller navigates from JavaScript instead.
export async function popToRootNatively(): Promise<boolean> {
  if (Platform.OS !== 'ios') return false;
  try {
    return await requireNativeModule<{ popToRoot(): Promise<boolean> }>('AbstractInternet').popToRoot();
  } catch { return false; /* A stale local build lacks the native function. */ }
}
