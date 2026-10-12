import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config.ts';

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      include: ['test/**/*.test.{ts,tsx}'],
      environment: 'node',
      // Tests never touch Bluetooth or the network: transports are fakes.
      restoreMocks: true,
    },
  }),
);
