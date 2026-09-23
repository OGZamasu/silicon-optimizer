/**
 * The one address every Live helper client uses: the CLI, the trusted
 * controller link, and the inspected page (its /live.js tag, CSP allowance
 * and fetches). The helper listens on 127.0.0.1 only, and `localhost` may
 * resolve to ::1 first, where any local process can listen on the same port
 * number: it would receive the CLI's controller credential, or serve the
 * page a script of its own. A leaf module, so framework adapters can import
 * it without pulling in the rest of lib/.
 */
export const LIVE_HELPER_HOST = '127.0.0.1';

export function liveHelperBase(port) {
  return `http://${LIVE_HELPER_HOST}:${Number(port)}`;
}
