import fs from 'node:fs';
import path from 'node:path';

import { LIVE_CHROME_MOUNT_CONTRACT, LIVE_UI_SURFACES } from './ui-surfaces.mjs';

export const LIVE_BROWSER_SCRIPT_PARTS = Object.freeze([
  Object.freeze({ name: 'session-state', file: 'live-browser-session.js' }),
  Object.freeze({ name: 'dom-helpers', file: 'live-browser-dom.js' }),
  Object.freeze({ name: 'browser-ui', file: 'live-browser.js' }),
]);

export function resolveLiveBrowserScriptParts(scriptsDir, parts = LIVE_BROWSER_SCRIPT_PARTS) {
  if (!scriptsDir) throw new Error('scriptsDir is required');
  return parts.map((part, index) => ({
    ...part,
    index,
    path: path.join(scriptsDir, part.file),
  }));
}

export function assertLiveBrowserScriptParts(parts, exists = fs.existsSync) {
  for (const part of parts) {
    if (!exists(part.path)) {
      throw new Error(`Live browser script part missing: ${part.name} (${part.path})`);
    }
  }
  return parts;
}

export function readLiveBrowserScriptParts(parts, readFile = (filePath) => fs.readFileSync(filePath, 'utf-8')) {
  return parts.map((part) => ({
    ...part,
    source: readFile(part.path),
  }));
}

export function assembleLiveBrowserScript({
  token,
  port,
  vocabulary,
  commandPrefix = '/',
  appRoot = null,
  parts,
  // Defaulted rather than threaded through live-server.mjs: the browser bundle
  // must always carry the canonical inventory, and a default makes that true by
  // construction instead of by every caller remembering to pass it. Overridable
  // so tests can assemble with a stand-in.
  uiSurfaces = LIVE_UI_SURFACES,
  mountContract = LIVE_CHROME_MOUNT_CONTRACT,
}) {
  // Project identity, command vocabulary, and chrome inventory are serialized
  // for the classic browser bundle. Keep them in a closure instead of durable
  // window properties so bearer material is not needlessly exposed after init.
  const prelude = `(() => {\nconst __IMPECCABLE_BOOTSTRAP__ = Object.freeze(${JSON.stringify({
    token,
    port,
    appRoot,
    commandPrefix,
    vocabulary,
    uiSurfaces,
    mountContract,
  })});\n`;

  const body = parts.map((part) => {
    const file = part.file || path.basename(part.path || '');
    return `// --- impeccable live script part: ${part.name} (${file}) ---\n${part.source}`;
  }).join('\n');

  return prelude + body + '\n})();\n';
}
