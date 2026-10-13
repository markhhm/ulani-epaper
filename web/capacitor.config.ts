import type { CapacitorConfig } from '@capacitor/cli';

// The Android app: the web build in dist/ inside a WebView, with the native
// Bluetooth LE plugin (src/ble/capacitorBle.ts) and the app's own plugins
// (android/app/src/main/java/...). It opens on the app (index.html), which
// links to the diagnostics page. `npx cap sync android` copies dist/ and this
// configuration into android/.
const config: CapacitorConfig = {
  appId: 'io.github.markhhm.paperhue',
  appName: 'Paperhue',
  webDir: 'dist',
};

export default config;
