/**
 * The inspected page needs progress counts, not agent logs or source snippets.
 * Full diagnostics stay in controller-only /status and optional local logs.
 */
export function pageSafeManualEditActivity(entry = {}) {
  const out = { type: entry.type, seq: entry.seq, ts: entry.ts };
  if (typeof entry.pageUrl === 'string') out.pageUrl = entry.pageUrl.slice(0, 2048);
  for (const key of ['pendingCount', 'remainingCount', 'totalCount', 'appliedCount',
    'failedCount', 'cleared']) {
    if (Number.isSafeInteger(entry[key]) && entry[key] >= 0) out[key] = entry[key];
  }
  if (entry.repairOnly === true) out.repairOnly = true;
  if (entry.needsManualDecision === true) out.needsManualDecision = true;
  if (entry.reason === 'manual_edit_repair_needs_decision') out.reason = entry.reason;
  if (entry.chunk && typeof entry.chunk === 'object') {
    out.chunk = {};
    for (const key of ['opCount', 'totalOpCount']) {
      if (Number.isSafeInteger(entry.chunk[key]) && entry.chunk[key] >= 0) out.chunk[key] = entry.chunk[key];
    }
  }
  if (entry.repair && typeof entry.repair === 'object') {
    out.repair = {};
    for (const key of ['attempt', 'attempts', 'maxAttempts']) {
      if (Number.isSafeInteger(entry.repair[key]) && entry.repair[key] >= 0) out.repair[key] = entry.repair[key];
    }
  }
  return out;
}

/** Agent replies can contain source excerpts and compile diagnostics. The
 * inspected page only needs a terminal status, published file metadata, and
 * the carbonize completion bit; full reply detail remains in the journal. */
export function pageSafeAgentReply(reply = {}, fileMeta = {}) {
  const type = typeof reply.type === 'string' && reply.type ? reply.type : 'done';
  const out = { type, id: reply.id };
  if (type === 'error') out.message = 'Agent action failed. Review the trusted controller or agent log for details.';
  else if (type === 'steer_done') out.message = 'Steer complete.';
  for (const key of ['file', 'sourceFile', 'previewFile', 'previewMode']) {
    if (typeof fileMeta[key] === 'string') out[key] = fileMeta[key];
  }
  if (reply.data?.carbonize === true) out.data = { carbonize: true };
  return out;
}
