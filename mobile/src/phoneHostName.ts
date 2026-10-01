import { Platform } from 'react-native';
import { requireNativeModule } from 'expo-modules-core';

export function phoneHostName(): string {
  if (Platform.OS === 'ios') {
    try {
      const host = requireNativeModule<{ hostName(): string }>('AbstractInternet').hostName().trim();
      if (host && host !== 'localhost') return host.replace(/(?:\.coredevice)?\.local\.?$/i, '');
    } catch { /* A stale local build can still connect with a generic name. */ }
    return 'iPhone';
  }
  return Platform.OS === 'android' ? Platform.constants.Model || 'Android device' : 'Mobile device';
}
