import type { CapacitorConfig } from '@capacitor/cli';

// The Android app: the web build in dist/ inside a WebView, with the native
// Bluetooth LE plugin (src/ble/capacitorBle.ts). `npx cap sync android`
// copies dist/ and this configuration into android/.
const config: CapacitorConfig = {
  appId: 'io.github.markhhm.paperhue',
  appName: 'Paperhue',
  webDir: 'dist',
  server: {
    // Until the app UI exists, the app opens on the diagnostics page, which
    // links back to index.html (and index.html links to it).
    appStartPath: '/spike.html',
  },
};

export default config;
