/**
 * The live-accept.mjs arguments for an approved accept or discard: the ones the
 * poll script runs it with, and the ones the agent is told to rerun it with
 * when a publisher holds the source lock.
 *
 * No page-supplied free text rides here as a word of its own: live-accept
 * matches flags anywhere in argv, so a pageUrl of "--discard" would turn an
 * approved Accept into a discard. The id and variant are validated to hex and
 * digits before an event is queued; the page's param values ride glued to
 * their flag, like every page value the Live helpers are handed.
 */
export function buildAcceptScriptArgs(event) {
  const scriptArgs = event.type === 'discard'
    ? ['--id', String(event.id), '--discard']
    : ['--id', String(event.id), '--variant', String(event.variantId)];
  if (event.type === 'accept' && event.paramValues && Object.keys(event.paramValues).length > 0) {
    scriptArgs.push(`--param-values=${JSON.stringify(event.paramValues)}`);
  }
  return scriptArgs;
}
