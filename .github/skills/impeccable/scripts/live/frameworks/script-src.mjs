/**
 * The one place that builds the `/live.js` URL the browser loads.
 *
 * Every injection path needs it (the generic script tag, the Nuxt client
 * plugin, the SvelteKit root component, the TanStack mount component), and a
 * separate module keeps that shared leaf free of import cycles: the framework
 * entries import it, and nothing here imports a framework entry.
 */

import { liveHelperBase } from '../../lib/live-helper-origin.mjs';

/**
 * Only the page-scoped token may be supplied here. The source URL is readable
 * by every script in the inspected page and must never carry the controller
 * credential. The host is 127.0.0.1, never `localhost`: a process holding the
 * same port on ::1 would otherwise serve the page its own script.
 */
export function buildLiveScriptSrc(port, token) {
  const base = liveHelperBase(port) + '/live.js';
  return token ? base + '?token=' + encodeURIComponent(token) : base;
}
