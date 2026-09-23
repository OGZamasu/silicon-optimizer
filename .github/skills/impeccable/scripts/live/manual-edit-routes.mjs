import { validateEvent } from './event-validation.mjs';
import {
  countByPage as countPendingByPage,
  readBuffer as readManualEditsBuffer,
  readBufferStrict as readManualEditsBufferStrict,
  reviewDigest as manualEditReviewDigest,
  removeEntries as removeManualEditEntries,
  stageEntry as stageManualEditEntry,
  truncateBuffer as truncateManualEditsBuffer,
} from './manual-edits-buffer.mjs';
import {
  summarizeManualApplyFailures,
  summarizeManualDiagnostics,
  summarizeManualLogFile,
} from './manual-apply.mjs';
import { buildManualEditEvidence } from '../live-manual-edit-evidence.mjs';
import { commitManualEdits } from '../live-commit-manual-edits.mjs';

export function createManualEditRoutes({
  getToken,
  manualApply,
  recordManualEditActivity,
  getManualEditStatus,
  chatAgentLikelyActive,
  authorizePost,
  authorizeStashPost = authorizePost,
  readJson,
  sendInputError,
  cwd = () => process.cwd(),
  env = () => process.env,
} = {}) {
  const projectCwd = () => typeof cwd === 'function' ? cwd() : cwd || process.cwd();
  const currentEnv = () => typeof env === 'function' ? env() : env || process.env;
  let commitInProgress = false;

  return function handleManualEditRoute(req, res, url) {
    const p = url.pathname;

    // Save stages entries; Apply commits the staged page batch through the
    // local AI copy-edit runner.
    if (p === '/manual-edit-stash' && req.method === 'POST') {
      if (!authorizeStashPost(req, res)) return true;
      readJson(req).then((msg) => {
        const error = validateEvent({ ...msg, type: 'manual_edits' });
        if (error) {
          sendJson(res, 400, { error });
          return;
        }
        try {
          stageManualEditEntry(projectCwd(), {
            id: msg.id,
            pageUrl: msg.pageUrl,
            element: msg.element,
            ops: msg.ops,
          });
        } catch (err) {
          sendJson(res, err?.code === 'MANUAL_EDIT_BUFFER_LIMIT' ? 429 : 500, {
            error: err?.code === 'MANUAL_EDIT_BUFFER_LIMIT' ? 'manual_edit_buffer_limit' : 'stash_write_failed',
            message: err?.code === 'MANUAL_EDIT_BUFFER_LIMIT'
              ? 'Staged copy edits are full; review them in the trusted controller before saving more.'
              : 'Could not stage this edit; check the trusted controller for details.',
          });
          return;
        }
        const { totalCount, perPage } = countPendingByPage(projectCwd());
        const pendingCount = perPage[msg.pageUrl] || 0;
        recordManualEditActivity('manual_edit_stashed', {
          id: msg.id,
          pageUrl: msg.pageUrl,
          opCount: msg.ops.length,
          pendingCount,
          totalCount,
          hintedFileCount: new Set((msg.ops || []).map((op) => summarizeManualLogFile(op.sourceHint?.file, projectCwd())).filter(Boolean)).size,
        });
        sendJson(res, 200, { ok: true, pendingCount, totalCount });
      }).catch((error) => sendInputError(req, res, error));
      return true;
    }

    if (p === '/manual-edit-stash' && req.method === 'GET') {
      const token = url.searchParams.get('token');
      if (token !== getToken()) { res.writeHead(401); res.end('Unauthorized'); return true; }
      const pageUrl = url.searchParams.get('pageUrl') || '';
      const { totalCount, perPage } = countPendingByPage(projectCwd());
      const buffer = readManualEditsBuffer(projectCwd());
      const entriesForPage = pageUrl ? buffer.entries.filter((e) => e.pageUrl === pageUrl) : buffer.entries;
      const pageDigests = Object.fromEntries(
        [...new Set(buffer.entries.map((entry) => entry.pageUrl).filter(Boolean))]
          .map((page) => [page, manualEditReviewDigest(buffer.entries.filter((entry) => entry.pageUrl === page))]),
      );
      const repair = manualApply.readTransaction();
      sendJson(res, 200, {
        count: pageUrl ? (perPage[pageUrl] || 0) : totalCount,
        totalCount,
        perPage,
        entries: entriesForPage,
        pageDigests,
        commitInProgress,
        repairPageUrl: repair?.pageUrl ?? null,
        repair: repair ? {
          id: repair.id,
          pageUrl: repair.pageUrl ?? null,
          createdAt: repair.createdAt ?? null,
          fileCount: Array.isArray(repair.files) ? repair.files.length : 0,
          files: (Array.isArray(repair.files) ? repair.files : []).slice(0, 100).map((item) => ({
            file: item?.file,
            existedBefore: item?.exists === true,
            beforeBytes: Buffer.byteLength(String(item?.content || '')),
          })),
          retryAvailable: Array.isArray(repair.reviewedEntries),
        } : null,
      });
      return true;
    }

    if (p === '/manual-edit-commit' && req.method === 'POST') {
      if (!authorizePost(req, res)) return true;
      if (commitInProgress) {
        sendJson(res, 409, { error: 'manual_edit_commit_in_progress' });
        return true;
      }
      const pageUrl = url.searchParams.get('pageUrl') || null;
      const asyncMode = /^(1|true|yes)$/i.test(url.searchParams.get('async') || '');
      const repairOnly = /^(1|true|yes)$/i.test(url.searchParams.get('repair') || '');
      const existingTransaction = manualApply.readTransaction();
      if (existingTransaction && !repairOnly) {
        sendJson(res, 409, { error: 'manual_edit_repair_decision_required' });
        return true;
      }
      if (repairOnly && (!existingTransaction || !Array.isArray(existingTransaction.reviewedEntries))) {
        sendJson(res, 409, { error: 'manual_edit_repair_transaction_missing' });
        return true;
      }
      if (repairOnly && existingTransaction.id !== url.searchParams.get('transactionId')) {
        sendJson(res, 409, { error: 'manual_edit_repair_review_changed' });
        return true;
      }
      if (repairOnly && existingTransaction.pageUrl !== pageUrl) {
        sendJson(res, 409, { error: 'manual_edit_repair_page_mismatch' });
        return true;
      }
      let reviewedEntries;
      try {
        reviewedEntries = repairOnly
          ? existingTransaction.reviewedEntries
          : readManualEditsBufferStrict(projectCwd()).entries
            .filter((entry) => !pageUrl || entry.pageUrl === pageUrl);
        if (!repairOnly && req.headers['x-impeccable-review-digest'] !== manualEditReviewDigest(reviewedEntries)) {
          sendJson(res, 409, { error: 'manual_edit_review_changed' });
          return true;
        }
      } catch (error) {
        sendJson(res, 500, { error: 'manual_edit_review_failed', message: error.message });
        return true;
      }
      let commitBatch;
      try {
        commitBatch = buildManualEditEvidence({ cwd: projectCwd(), pageUrl, entries: reviewedEntries });
      } catch (error) {
        sendJson(res, 500, { error: 'manual_edit_evidence_failed', message: error.message });
        return true;
      }
      const before = getManualEditStatus();
      const pendingCount = manualApply.countOps(commitBatch);
      recordManualEditActivity('manual_edit_commit_started', {
        pageUrl,
        repairOnly,
        pendingCount,
        totalCount: before.totalCount,
        ...summarizePendingManualEditBatch(projectCwd(), pageUrl),
      });
      if (asyncMode) {
        sendJson(res, 202, {
          status: 'started',
          pendingCount,
          totalCount: before.totalCount,
          perPage: before.perPage,
        });
      }
      commitInProgress = true;
      (async () => {
        try {
        let result;
        let routedProvider = 'subprocess';
        let transaction = null;
        try {
          if (pendingCount > 0) {
            if (!repairOnly) {
              transaction = manualApply.writeTransaction({
                pageUrl,
                batch: commitBatch,
              });
            } else if (repairOnly && existingTransaction) {
              transaction = existingTransaction;
            }
          }
          const envValue = currentEnv();
          const requestedMode = (envValue.IMPECCABLE_LIVE_COPY_AGENT || 'auto').trim().toLowerCase();
          const useChatRoute = requestedMode === 'chat'
            || (requestedMode === 'auto' && chatAgentLikelyActive());
          if (useChatRoute) {
            routedProvider = 'chat';
            const timeoutMs = Number(envValue.IMPECCABLE_LIVE_COPY_AGENT_TIMEOUT_MS || 120000);
            result = await commitManualEdits({
              cwd: projectCwd(),
              pageUrl,
              provider: 'chat',
              env: envValue,
              timeoutMs,
              chatAvailable: chatAgentLikelyActive,
              applyBatchToSource: (batch, context) => manualApply.pushBatchInChunksAndWait(batch, pageUrl, context),
              repairOnly,
              transactionId: transaction?.id || existingTransaction?.id || null,
              batch: commitBatch,
            });
          } else {
            const timeoutMs = Number(envValue.IMPECCABLE_LIVE_COPY_AGENT_TIMEOUT_MS || 120000);
            const provider = ['codex', 'claude', 'mock'].includes(requestedMode) ? requestedMode : undefined;
            result = await commitManualEdits({
              cwd: projectCwd(),
              pageUrl,
              provider,
              env: envValue,
              timeoutMs,
              chatAvailable: chatAgentLikelyActive,
              repairOnly,
              transactionId: transaction?.id || existingTransaction?.id || null,
              batch: commitBatch,
            });
          }
        } catch (err) {
          if (transaction) {
            manualApply.rollbackTransaction({
              pageUrl,
              reason: 'manual_edit_commit_exception',
            });
          }
          const message = err.stderr?.toString?.() || err.message;
          recordManualEditActivity('manual_edit_commit_failed', {
            pageUrl,
            provider: routedProvider,
            error: 'manual_edit_commit_failed',
            message,
            transactionId: transaction?.id || null,
          });
          if (!asyncMode) {
            sendJson(res, 500, {
              error: 'manual_edit_commit_failed',
              message,
            });
          }
          return;
        } finally {
          if (transaction) {
            const shouldKeepTransaction = result?.needsManualDecision === true;
            if (!shouldKeepTransaction) manualApply.clearTransaction(transaction.id);
          }
        }
        const { totalCount, perPage } = countPendingByPage(projectCwd());
        if (result?.needsManualDecision) {
          recordManualEditActivity('manual_edit_repair_needs_decision', {
            pageUrl,
            provider: routedProvider,
            transactionId: transaction?.id || existingTransaction?.id || null,
            repair: result.repair || null,
            failed: summarizeManualApplyFailures(result.failed, projectCwd()),
            files: Array.isArray(result.files) ? result.files.slice(0, 20).map((file) => summarizeManualLogFile(file, projectCwd())).filter(Boolean) : [],
            remainingCount: pageUrl ? (perPage[pageUrl] || 0) : totalCount,
            totalCount,
          });
        } else {
          recordManualEditActivity('manual_edit_commit_done', {
            pageUrl,
            provider: routedProvider,
            reason: result.reason || null,
            repair: result.repair || null,
            appliedCount: Array.isArray(result.applied) ? result.applied.length : 0,
            failedCount: Array.isArray(result.failed) ? result.failed.length : 0,
            failed: summarizeManualApplyFailures(result.failed, projectCwd()),
            files: Array.isArray(result.files) ? result.files.slice(0, 20).map((file) => summarizeManualLogFile(file, projectCwd())).filter(Boolean) : [],
            warnings: summarizeManualDiagnostics(result.warnings, projectCwd()),
            rolledBackFiles: Array.isArray(result.rolledBackFiles) ? result.rolledBackFiles.slice(0, 20).map((file) => summarizeManualLogFile(file, projectCwd())).filter(Boolean) : [],
            rollbackFailures: summarizeManualDiagnostics(result.rollbackFailures, projectCwd()),
            unreportedFiles: Array.isArray(result.unreportedFiles) ? result.unreportedFiles.slice(0, 20).map((file) => summarizeManualLogFile(file, projectCwd())).filter(Boolean) : undefined,
            noteCount: Array.isArray(result.notes) ? result.notes.length : 0,
            cleared: result.cleared || 0,
            remainingCount: pageUrl ? (perPage[pageUrl] || 0) : totalCount,
            totalCount,
          });
        }
        if (!asyncMode) {
          sendJson(res, 200, { ...result, totalCount, perPage });
        }
        } finally {
          commitInProgress = false;
        }
      })();
      return true;
    }

    if (p === '/manual-edit-repair-decision' && req.method === 'POST') {
      if (!authorizePost(req, res)) return true;
      if (commitInProgress) { sendJson(res, 409, { error: 'manual_edit_commit_in_progress' }); return true; }
      readJson(req).then((payload) => {
        // The body reader yields; another Apply may have started in between.
        if (commitInProgress) { sendJson(res, 409, { error: 'manual_edit_commit_in_progress' }); return; }
        const pageUrl = payload.pageUrl || url.searchParams.get('pageUrl') || null;
        const transaction = manualApply.readTransaction();
        if (!transaction || transaction.pageUrl !== pageUrl) {
          sendJson(res, 409, { error: 'manual_edit_repair_page_mismatch' });
          return;
        }
        if (transaction.id !== payload.transactionId) {
          sendJson(res, 409, { error: 'manual_edit_repair_review_changed' });
          return;
        }
        const action = String(payload.action || url.searchParams.get('action') || '').trim().toLowerCase();
        if (action !== 'rollback') {
          sendJson(res, 400, { error: 'unsupported_manual_edit_repair_decision', action });
          return;
        }
        const rollback = manualApply.rollbackTransaction({
          pageUrl,
          reason: 'manual_edit_user_requested_rollback',
        });
        const { totalCount, perPage } = countPendingByPage(projectCwd());
        const response = {
          action,
          pageUrl,
          rollback,
          remainingCount: pageUrl ? (perPage[pageUrl] || 0) : totalCount,
          totalCount,
          perPage,
        };
        recordManualEditActivity('manual_edit_repair_rollback_done', response);
        sendJson(res, 200, response);
      }).catch((error) => sendInputError(req, res, error));
      return true;
    }

    if (p === '/manual-edit-discard' && req.method === 'POST') {
      if (!authorizePost(req, res)) return true;
      if (commitInProgress) { sendJson(res, 409, { error: 'manual_edit_commit_in_progress' }); return true; }
      if (manualApply.readTransaction()) { sendJson(res, 409, { error: 'manual_edit_repair_decision_required' }); return true; }
      const pageUrl = url.searchParams.get('pageUrl');
      try {
        const entries = readManualEditsBufferStrict(projectCwd()).entries
          .filter((entry) => !pageUrl || entry.pageUrl === pageUrl);
        if (req.headers['x-impeccable-review-digest'] !== manualEditReviewDigest(entries)) {
          sendJson(res, 409, { error: 'manual_edit_review_changed' });
          return true;
        }
      } catch (error) {
        sendJson(res, 500, { error: 'manual_edit_review_failed', message: error.message });
        return true;
      }
      let discarded;
      let discardedEntries = [];
      let canceledApplyEvents = [];
      let transactionRollback = null;
      try {
        const buffer = readManualEditsBuffer(projectCwd());
        transactionRollback = manualApply.rollbackTransaction({
          pageUrl,
          reason: 'manual_edit_discarded',
        });
        if (pageUrl) {
          discardedEntries = buffer.entries.filter((entry) => entry.pageUrl === pageUrl);
          discarded = removeManualEditEntries(projectCwd(), (entry) => entry.pageUrl === pageUrl);
        } else {
          discardedEntries = buffer.entries;
          discarded = truncateManualEditsBuffer(projectCwd());
        }
        canceledApplyEvents = manualApply.cancelPendingEvents(pageUrl);
      } catch (err) {
        sendJson(res, 500, { error: 'discard_failed', message: err.message });
        return true;
      }
      const { totalCount, perPage } = countPendingByPage(projectCwd());
      recordManualEditActivity('manual_edit_discarded', {
        pageUrl,
        discarded,
        canceledApplyIds: canceledApplyEvents.map((event) => event.id),
        transactionRollback: transactionRollback ? {
          id: transactionRollback.id,
          rolledBackFiles: transactionRollback.rolledBackFiles?.map((file) => summarizeManualLogFile(file, projectCwd())).filter(Boolean) || [],
          rollbackFailures: summarizeManualDiagnostics(transactionRollback.rollbackFailures, projectCwd()),
          skipped: transactionRollback.skipped,
        } : undefined,
        totalCount,
      });
      sendJson(res, 200, { discarded, entries: discardedEntries, canceledApplyEvents, totalCount, perPage });
      return true;
    }

    if (p === '/manual-edit' && req.method === 'POST') {
      if (!authorizePost(req, res)) return true;
      sendJson(res, 410, { error: '/manual-edit is removed; use /manual-edit-stash and /manual-edit-commit for staged copy edits.' });
      return true;
    }

    return false;
  };
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

function summarizePendingManualEditBatch(cwd, pageUrl = null) {
  try {
    const buffer = readManualEditsBuffer(cwd);
    const entries = (buffer.entries || [])
      .filter((entry) => !pageUrl || entry.pageUrl === pageUrl);
    return {
      pendingEntryCount: entries.length,
      pendingOpCount: entries.reduce((sum, entry) => sum + (entry.ops?.length || 0), 0),
    };
  } catch (err) {
    return { pendingSummaryError: err.message || String(err) };
  }
}
