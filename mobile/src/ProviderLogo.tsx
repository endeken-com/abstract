import React from 'react';
import { SvgXml } from 'react-native-svg';
import { SymbolView } from 'expo-symbols';
import providerLogos from './providerLogos.json';

export function ProviderLogo({ provider, size = 15 }: { provider: string; size?: number }) {
  const xml = (providerLogos as Record<string, string>)[provider.toLowerCase()];
  return xml
    ? <SvgXml xml={xml} width={size} height={size} />
    : <SymbolView name={{ ios: 'sparkles', android: 'auto_awesome' }} size={size} tintColor="#A4A4AD" style={{ width: size, height: size }} />;
}

export function providerMenuImage(provider: string) {
  return ({ claude: 'ProviderClaude', codex: 'ProviderCodex', opencode: 'ProviderOpenCode' } as Record<string, string>)[provider.toLowerCase()];
}
