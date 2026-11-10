import React from 'react';
import { SvgXml } from 'react-native-svg';
import { SymbolView } from 'expo-symbols';
import providerLogos from './providerLogos.json';
import { palette } from './theme';
import type { ProviderPresentation } from './types';
export { providerPresentation, providerLabel } from './providerPresentation';

const legacyAssets: Record<string, string> = { claude: 'ProviderClaude', codex: 'ProviderCodex', opencode: 'ProviderOpenCode', muse: 'ProviderMuse', gemini: 'ProviderGemini' };
// The Mac's Codex asset has a different name in the phone bundle.
const phoneAsset = (asset: string) => asset === 'ProviderOpenAI' ? 'ProviderCodex' : asset;

export function ProviderLogo({ provider, presentation, size = 15 }: { provider: string; presentation?: ProviderPresentation; size?: number }) {
  const asset = presentation?.asset ? phoneAsset(presentation.asset) : !presentation ? legacyAssets[provider] : undefined;
  const xml = presentation?.icon || (asset ? (providerLogos as Record<string, string>)[asset.replace(/^Provider/, '').toLowerCase()] : undefined);
  return xml
    ? <SvgXml xml={xml} width={size} height={size} />
    : <SymbolView name={{ ios: 'sparkles', android: 'auto_awesome' }} size={size} tintColor={palette.textSecondary} style={{ width: size, height: size }} />;
}

export function providerMenuImage(provider: string, presentation?: ProviderPresentation) {
  return presentation?.asset ? phoneAsset(presentation.asset) : !presentation ? legacyAssets[provider] : undefined;
}
