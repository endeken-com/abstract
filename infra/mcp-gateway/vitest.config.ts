import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.toml' },
      miniflare: {
        // Placeholders only: tests never use a real secret.
        bindings: {
          PUBLIC_ORIGIN: 'http://localhost',
          DEVICE_PEPPER: 'test-pepper-placeholder-not-a-secret-0000',
          MAC_TIMEOUT_MS: '400',
          CONSENT_TIMEOUT_MS: '3000',
          ACCESS_TOKEN_TTL_SECONDS: '900',
        },
      },
    }),
  ],
  test: { testTimeout: 20_000 },
});
