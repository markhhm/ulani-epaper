import preact from '@preact/preset-vite';
import { defineConfig } from 'vite';

export default defineConfig({
  // Relative asset URLs: the same build works under a GitHub Pages sub-path
  // and inside the Android app's WebView.
  base: './',
  plugins: [preact()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rolldownOptions: {
      input: {
        index: 'index.html',
        spike: 'spike.html',
      },
    },
  },
});
