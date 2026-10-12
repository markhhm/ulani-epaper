/**
 * Entry of the diagnostics page (spike.html): finds out whether this browser
 * can run Paperhue, step by step, against a real device.
 */

import './spike.css';
import { detectLocale } from '../i18n';
import { Diagnostics } from './diagnostics';
import { technicalDetail } from './errors';
import { mountSpike } from './view';

// The saved choice of the language button, else the browser's languages.
detectLocale();

const root = document.getElementById('spike');
if (root) {
  const diagnostics = new Diagnostics();
  // Anything that slips through still ends up in the copied log.
  window.addEventListener('error', (event) => {
    diagnostics.log.add('error', `uncaught: ${event.message} (${event.filename}:${event.lineno}:${event.colno})`);
  });
  window.addEventListener('unhandledrejection', (event) => {
    diagnostics.log.add('error', `unhandled rejection: ${technicalDetail(event.reason).replace(/\n/g, ' | ')}`);
  });
  mountSpike(root, diagnostics);
}
