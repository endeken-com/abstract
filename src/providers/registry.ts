/**
 * Provider registry.
 *
 * Adding a provider = one file in this directory + one line in `PROVIDERS`.
 */

import type { ProviderDefinition } from './types';
import { claudeProvider } from './claude';
import { codexProvider } from './codex';

export const PROVIDERS: ProviderDefinition[] = [claudeProvider, codexProvider];

export function getProvider(id: string): ProviderDefinition {
  const provider = PROVIDERS.find((p) => p.id === id);
  if (!provider) {
    throw new Error(`Unknown provider: ${id} (known: ${providerIds().join(', ')})`);
  }
  return provider;
}

export function providerIds(): string[] {
  return PROVIDERS.map((p) => p.id);
}
