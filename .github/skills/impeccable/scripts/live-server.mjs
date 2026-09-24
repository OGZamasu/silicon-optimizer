#!/usr/bin/env node
/**
 * Live variant mode server (self-contained, zero dependencies).
 *
 * Serves the browser script (/live.js), the detection overlay (/detect.js),
 * uses Server-Sent Events (SSE) for server→browser push, and HTTP POST for
 * browser→server events. Agent communicates via HTTP long-poll (/poll).
 *
 * Usage:
 *   node <scripts_path>/live-server.mjs              # start
 *   node <scripts_path>/live-server.mjs stop         # stop + remove injected live.js tag
 *   node <scripts_path>/live-server.mjs stop --keep-inject   # stop only
 *   node <scripts_path>/live-server.mjs --help
 */

import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { parseDesignMd } from './lib/design-parser.mjs';
import { loadContext } from './context.mjs';
import {
  assembleLiveBrowserScript,
  assertLiveBrowserScriptParts,
  readLiveBrowserScriptParts,
  resolveLiveBrowserScriptParts,
} from './live/browser-script-parts.mjs';
import { createLiveSessionStore, GENERATION_FENCED_PHASES } from './live/session-store.mjs';
import { runGenerationPreflight } from './live/generation-preflight.mjs';
import { validateEvent } from './live/event-validation.mjs';
import { selectAvailablePendingEvent } from './live/poll-lanes.mjs';
import { createManualEditRoutes } from './live/manual-edit-routes.mjs';
import { renderControlUi } from './live/control-ui.mjs';
import { pageSafeAgentReply, pageSafeManualEditActivity } from './live/page-safe-activity.mjs';
import { createPendingDispatchAuth } from './live/pending-dispatch-auth.mjs';
import {
  CHECKPOINT_REASONS,
  AGENT_PHASES,
  LIVE_COMMANDS,
  SESSION_PHASES,
  VARIANT_PROGRESS_CHECKPOINT_REASONS as VARIANT_PROGRESS_CHECKPOINT_REASON_LIST,
} from './live/vocabulary.mjs';
import {
  getDesignSidecarPath,
  getLivePrivateDir,
  getLiveAnnotationsDir,
  IMPECCABLE_COMMAND_PREFIX,
  isLiveServerPidReachable,
  liveControllerUrl,
  liveHelperBase,
  livePrivateDirIsVolatile,
  migrateLegacyLivePrivateArtifacts,
  readLiveServerInfo,
  removeLiveServerInfo,
  resolveDesignSidecarPath,
  writeLiveServerInfo,
} from './lib/impeccable-paths.mjs';
import { countByPage as countPendingByPage, readBufferStrict as readManualEditsBufferStrict } from './live/manual-edits-buffer.mjs';
import {
  createManualApplyController,
  MAX_MANUAL_APPLY_EVIDENCE_BYTES,
  manualApplyEvidenceDir,
  summarizeManualApplyFailures,
} from './live/manual-apply.mjs';
import {
  bumpSvelteComponentPreviewRevision,
  compileCheckVariants,
  removeAllSvelteComponentSessions,
  quarantineLegacySvelteComponentSessions,
} from './live/svelte-component.mjs';
import { enterLiveRoot } from './live/roots.mjs';
import { matchesTemplateExtension, resolveLiveTemplateExtensions } from './lib/template-extensions.mjs';
import { atomicWriteFileInside, readFileInside, resolvePathInside } from './lib/security-boundaries.mjs';
import { LIVE_HELPER_HOST } from './lib/live-helper-origin.mjs';
import {
  applyDefensiveServerTimeouts,
  readBoundedBody,
  readBoundedJson,
  requireRequestToken,
  requestToken,
  sendHttpInputError,
  tokenMatches,
} from './lib/http-security.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// Anchor the whole process on the live roots manifest before anything derives
// a path from cwd. A server started from the wrong directory re-roots itself
// onto the appRoot the boot decided on instead of minting a second project.
const LIVE_ROOTS = enterLiveRoot(process.cwd());

// PRODUCT.md / DESIGN.md context, resolved lazily and per request so a server
// that outlives an `impeccable document` run (or a context file created after
// boot) reports current truth instead of a boot-time snapshot. The roots
// manifest wins when the ambient resolution misses (nested app inheriting
// repo-level context files).
function resolveProjectContext() {
  const ctx = loadContext(process.cwd());
  const designPath = ctx.designPath
    ? path.resolve(process.cwd(), ctx.designPath)
    : (LIVE_ROOTS?.designPath && fs.existsSync(LIVE_ROOTS.designPath) ? LIVE_ROOTS.designPath : null);
  const hasProduct = ctx.hasProduct
    || !!(LIVE_ROOTS?.productPath && fs.existsSync(LIVE_ROOTS.productPath));
  return {
    ...ctx,
    hasProduct,
    hasDesign: !!designPath,
    resolvedDesignPath: designPath,
    contextDir: ctx.contextDir || LIVE_ROOTS?.contextRoot || process.cwd(),
    designContextDir: ctx.designContextDir
      || (designPath ? path.dirname(designPath) : null),
  };
}
const DEFAULT_POLL_TIMEOUT = 600_000;   // 10 min — agent re-polls on timeout anyway
const SSE_HEARTBEAT_INTERVAL = 30_000;  // keepalive ping every 30s

// The browser events allowed to mint a NEW session journal. `generate` starts
// a variant session at Go; `steer` mints its own request id. Every other
// id-carrying event must land on an existing session (see the unknown_session
// gate in the /events handler).
const SESSION_CREATING_EVENT_TYPES = new Set(['generate', 'steer']);
// The browser checkpoints for several unrelated reasons (see checkpointPayload
// in live-browser.js). Only these two report that variant availability changed,
// and only they may drive variant_progress / the *_reviewable phases.
const VARIANT_PROGRESS_CHECKPOINT_REASONS = new Set(VARIANT_PROGRESS_CHECKPOINT_REASON_LIST);

// ---------------------------------------------------------------------------
// Port detection
// ---------------------------------------------------------------------------

async function findOpenPort(start = 8400) {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.listen(start, LIVE_HELPER_HOST, () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
    srv.on('error', () => resolve(findOpenPort(start + 1)));
  });
}

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

const state = {
  token: null,
  pageToken: null,
  port: null,
  sseClients: new Set(),   // SSE response objects (server→browser push)
  pendingEvents: [],        // browser events waiting for agent ack ({ event, leaseUntil })
  pendingPolls: [],         // agent poll callbacks waiting for browser events
  nextEventSeq: 1,
  lastAgentPollingBroadcast: null,
  sessionDir: null,         // per-session tmp dir for annotation screenshots
  sessionStore: null,
  pendingDispatchAuth: null,
  leaseTimer: null,
  manualEditActivity: null,
  nextManualEditSeq: 1,
  // Deferreds for in-flight chat-routed Apply events. Keyed by event id; each
  // entry is resolved when the chat agent POSTs an ack carrying the batch
  // result, or rejected when the hard timeout fires.
  pendingApplyDeferreds: new Map(),
  // Updated whenever a /poll long-poll request arrives or is resolved with an
  // event. Used to detect "a chat agent is likely attached" without requiring
  // a poll to be parked at the exact moment we dispatch.
  lastPollAt: 0,
  timedOutApplyIds: new Map(),
  pageApprovals: new Map(),
  pageApprovalOutcomes: new Map(),
  annotationSizes: new Map(),
  annotationBytes: 0,
  pageCheckpointLastAt: new Map(),
};

const CHAT_POLL_FRESHNESS_MS = 60_000;
const POLL_LEASE_EXPIRY_TIMER_GRACE_MS = 2;
const DEBUG_MANUAL_EDIT_EVENTS = /^(1|true|yes)$/i.test(process.env.IMPECCABLE_LIVE_DEBUG_EVENTS || '');

const manualApply = createManualApplyController({
  pendingEvents: state.pendingEvents,
  pendingApplyDeferreds: state.pendingApplyDeferreds,
  timedOutApplyIds: state.timedOutApplyIds,
  enqueueEvent,
  acknowledgePendingEvent,
  flushPendingPolls,
  recordManualEditActivity,
  cwd: () => process.cwd(),
});

const manualEditRoutes = createManualEditRoutes({
  getToken: () => state.token,
  authorizePost: (req, res) => requireLivePostAuth(req, res),
  authorizeStashPost: (req, res) => requirePagePostAuth(req, res),
  readJson: (req) => readBoundedJson(req, { maxBytes: MAX_LIVE_JSON_BYTES }),
  sendInputError: (req, res, error) => sendHttpInputError(req, res, error),
  manualApply,
  recordManualEditActivity,
  getManualEditStatus,
  chatAgentLikelyActive,
  cwd: () => process.cwd(),
  env: () => process.env,
});

function chatAgentLikelyActive() {
  if (state.pendingPolls.length > 0) return true;
  if (!state.lastPollAt) return false;
  return Date.now() - state.lastPollAt < CHAT_POLL_FRESHNESS_MS;
}

// Cap per-annotation upload size. A full 1920×1080 PNG is typically <1 MB;
// cap at 10 MB to guard against runaway writes from a misbehaving client.
const MAX_ANNOTATION_BYTES = 10 * 1024 * 1024;
const MAX_ANNOTATION_FILES = 64;
const MAX_ANNOTATION_TOTAL_BYTES = 64 * 1024 * 1024;
const MAX_LIVE_JSON_BYTES = 1024 * 1024;
const LIVE_SOURCE_AUX_EXTENSIONS = Object.freeze(['.css', '.scss', '.sass', '.less']);
const PAGE_TELEMETRY_TYPES = new Set(['checkpoint', 'variant_mounted']);
const PERSISTED_PENDING_TYPES = new Set([
  'generate', 'accept', 'accept_intent', 'discard', 'steer',
  'carbonize_cleanup', 'variant_mount_failed',
]);
// Exactly the fields live-browser.js sends for each action it may propose.
// Approval turns a proposal into a controller event, and the agent trusts
// helper-authored fields on such events as plumbing (a scaffold names the
// file and lines to rewrite; `_instructions` is "the authoritative next
// step"), so anything else is dropped before the controller reviews it.
// `carbonize_cleanup` is agent-side work; the browser never proposes it.
const PAGE_PROPOSAL_FIELDS = Object.freeze({
  generate: new Set(['type', 'id', 'mode', 'action', 'freeformPrompt', 'count', 'pageUrl',
    'element', 'insert', 'placeholder', 'comments', 'strokes', 'screenshotPath', 'clientSentAt']),
  accept: new Set(['type', 'id', 'variantId', 'paramValues', 'pageUrl', 'clientSentAt']),
  discard: new Set(['type', 'id', 'orphaned']),
  steer: new Set(['type', 'id', 'message', 'pageUrl']),
  variant_mount_failed: new Set(['type', 'id', 'variant', 'url', 'error']),
  prefetch: new Set(['type', 'pageUrl']),
  exit: new Set(['type']),
});
const PAGE_ACTION_TYPES = new Set(Object.keys(PAGE_PROPOSAL_FIELDS));
const MAX_PENDING_PAGE_APPROVALS = 8;
const MAX_PAGE_APPROVAL_BYTES = MAX_LIVE_JSON_BYTES;
const MAX_PENDING_PAGE_APPROVAL_BYTES = 2 * MAX_LIVE_JSON_BYTES;
const MAX_PAGE_CHECKPOINT_PARAM_BYTES = 4 * 1024;
const MAX_PAGE_TELEMETRY_JOURNAL_BYTES = 16 * 1024 * 1024;
const PAGE_CHECKPOINT_MIN_INTERVAL_MS = 100;
const CHECKPOINT_REASON_SET = new Set(CHECKPOINT_REASONS);
const PAGE_SAFE_SESSION_PHASES = new Set([...SESSION_PHASES, 'generating', 'cycling']);
const AGENT_PHASE_SET = new Set(AGENT_PHASES);
const PAGE_APPROVAL_TIMEOUT_MS = 5 * 60 * 1000;
const PAGE_APPROVAL_OUTCOME_TTL_MS = 5 * 60 * 1000;
const MAX_PAGE_APPROVAL_OUTCOMES = 128;

function requireLivePostAuth(req, res) {
  if (req.headers.origin && !isSameControllerOrigin(req)) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'controller_origin_required' }));
    return false;
  }
  return requireRequestToken(req, res, state.token, { headerName: 'x-impeccable-token' });
}

function isSameControllerOrigin(req) {
  const host = req.headers.host;
  const allowed = new Set([`localhost:${state.port}`, `127.0.0.1:${state.port}`]);
  return typeof host === 'string' && allowed.has(host) && req.headers.origin === `http://${host}`;
}

function requirePagePostAuth(req, res) {
  return requireRequestToken(req, res, state.pageToken, { headerName: 'x-impeccable-token' });
}

function requireQueryToken(url, res, expected) {
  if (tokenMatches(url.searchParams.get('token'), expected)) return true;
  res.writeHead(401, { 'Content-Type': 'text/plain' });
  res.end('Unauthorized');
  return false;
}

function recordPageApprovalOutcome(id, status, body) {
  const outcome = { status, body };
  state.pageApprovalOutcomes.set(id, outcome);
  while (state.pageApprovalOutcomes.size > MAX_PAGE_APPROVAL_OUTCOMES) {
    state.pageApprovalOutcomes.delete(state.pageApprovalOutcomes.keys().next().value);
  }
  const timer = setTimeout(() => {
    if (state.pageApprovalOutcomes.get(id) === outcome) state.pageApprovalOutcomes.delete(id);
  }, PAGE_APPROVAL_OUTCOME_TTL_MS);
  timer.unref?.();
}

function pageProposal(msg) {
  const allowed = PAGE_PROPOSAL_FIELDS[msg.type];
  return Object.fromEntries(Object.entries(msg).filter(([key]) => allowed.has(key)));
}

function queuePageApproval(res, msg) {
  const approvalId = randomUUID();
  const proposal = pageProposal(msg);
  // An Accept must not fall back to mutable checkpoint params after the user
  // has reviewed this exact proposal in the trusted controller.
  const frozen = proposal.type === 'accept' && proposal.paramValues === undefined
    ? { ...proposal, paramValues: {} }
    : proposal;
  const bytes = Buffer.byteLength(JSON.stringify(frozen));
  if (bytes > MAX_PAGE_APPROVAL_BYTES) {
    res.writeHead(413, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'approval_payload_too_large' }));
    return;
  }
  const pendingBytes = [...state.pageApprovals.values()].reduce((sum, item) => sum + item.bytes, 0);
  if (state.pageApprovals.size >= MAX_PENDING_PAGE_APPROVALS
      || pendingBytes + bytes > MAX_PENDING_PAGE_APPROVAL_BYTES) {
    res.writeHead(429, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'too_many_pending_approvals' }));
    return;
  }
  const approval = { id: approvalId, msg: frozen, bytes, createdAt: Date.now(), timer: null };
  approval.timer = setTimeout(() => {
    if (state.pageApprovals.get(approvalId) !== approval) return;
    recordPageApprovalOutcome(approvalId, 408, { error: 'controller_approval_timed_out' });
    state.pageApprovals.delete(approvalId);
  }, PAGE_APPROVAL_TIMEOUT_MS);
  approval.timer.unref?.();
  state.pageApprovals.set(approvalId, approval);
  res.writeHead(202, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify({ pendingApproval: true, id: approvalId }));
}

async function resolvePageApproval(approvalId, decision) {
  const approval = state.pageApprovals.get(approvalId);
  if (!approval || approval.dispatching) return false;
  approval.dispatching = true;
  clearTimeout(approval.timer);
  if (decision === 'reject') {
    recordPageApprovalOutcome(approvalId, 403, { error: 'controller_rejected_action' });
    state.pageApprovals.delete(approvalId);
    return true;
  }
  try {
    const response = await fetch(`${liveHelperBase(state.port)}/events`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Impeccable-Token': state.token },
      body: JSON.stringify(approval.msg),
      signal: AbortSignal.timeout(15_000),
    });
    // Internal action responses can include source-derived diagnostics. The
    // page only learns whether its exact approved action dispatched.
    recordPageApprovalOutcome(approvalId, response.status,
      response.ok ? { ok: true } : { error: 'approved_action_failed' });
  } catch {
    recordPageApprovalOutcome(approvalId, 502, { error: 'controller_dispatch_failed' });
  }
  state.pageApprovals.delete(approvalId);
  return true;
}

function isAllowedLiveSource(filePath) {
  if (matchesTemplateExtension(filePath, resolveLiveTemplateExtensions(process.cwd()))) return true;
  const lower = filePath.toLowerCase();
  if (LIVE_SOURCE_AUX_EXTENSIONS.some((extension) => lower.endsWith(extension))) return true;
  if (!lower.endsWith('.json')) return false;
  const relative = path.relative(process.cwd(), filePath).split(path.sep).join('/');
  return relative.startsWith('.impeccable/live/')
    || relative.startsWith('node_modules/.impeccable-live/');
}

function pageSafeFileMetadata(meta = {}) {
  const out = {};
  const root = process.cwd();
  const templateExtensions = resolveLiveTemplateExtensions(root);
  for (const key of ['file', 'sourceFile', 'previewFile']) {
    const value = meta[key];
    if (typeof value !== 'string' || value.length > 512 || /[\x00-\x1f\x7f]/.test(value)) continue;
    try {
      const full = resolvePathInside(root, value, { kind: 'file' });
      const relative = path.relative(root, full).split(path.sep).join('/');
      if (relative.startsWith('.impeccable/') || relative.startsWith('node_modules/')) continue;
      if (!matchesTemplateExtension(full, templateExtensions)
          && !LIVE_SOURCE_AUX_EXTENSIONS.some((ext) => full.toLowerCase().endsWith(ext))) continue;
      out[key] = relative;
    } catch { /* untrusted reply strings never authorize another path */ }
  }
  if (meta.previewMode === 'source') out.previewMode = 'source';
  return out;
}

function enqueueEvent(event) {
  if (!event) return;
  // Dedupe by (session, type), except mount failures, which are per-variant:
  // variant 2 failing must not be swallowed because variant 1's failure is
  // still queued.
  const duplicate = event.id && state.pendingEvents.some((entry) => (
    entry.event?.id === event.id
    && entry.event?.type === event.type
    && (event.type !== 'variant_mount_failed' || entry.event?.variant === event.variant)
  ));
  if (duplicate) return;
  state.pendingEvents.push({ event, leaseUntil: 0, seq: state.nextEventSeq++ });
  flushPendingPolls();
}

function restorePendingEventsFromStore() {
  if (!state.sessionStore) return;
  for (const snapshot of state.sessionStore.listActiveSessions()) {
    const pending = snapshot.pendingEvent;
    if (!pending) continue;
    if (state.pendingDispatchAuth.verify(pending)) {
      enqueueEvent(pending);
      continue;
    }
    // Pre-upgrade journals could be authored by a page that held the old
    // shared credential. Preserve the journal, but never dispatch such work
    // into a new trusted-controller session without a fresh decision.
    state.sessionStore.appendEvent({ type: 'pending_event_retired', id: snapshot.id,
      retiredType: pending.type, reason: 'untrusted_legacy_pending_action' });
    console.warn(`[impeccable] retired untrusted pending ${pending.type} for session ${snapshot.id}; start a new action in the trusted controller`);
  }
}

function findAvailablePendingEvent(now = Date.now(), types = null) {
  return selectAvailablePendingEvent(state.pendingEvents, { now, types });
}

async function leaseEvent(entry, leaseMs) {
  // Claim the entry before awaiting anything. prepareGenerateEventForLease
  // yields to the event loop, and selectAvailablePendingEvent only skips
  // entries whose lease is in the future — an unclaimed entry would be handed
  // to a second poll in that window and generated twice.
  entry.leaseUntil = Date.now() + leaseMs;
  await prepareGenerateEventForLease(entry);
  if (!entry.event?.id) {
    const idx = state.pendingEvents.indexOf(entry);
    if (idx !== -1) state.pendingEvents.splice(idx, 1);
    return entry.event;
  }
  // Re-stamp so the lease window starts when the agent actually receives the
  // work, not when scaffolding began.
  entry.leaseUntil = Date.now() + leaseMs;
  recordGenerateDelivery(entry);
  scheduleLeaseFlush();
  broadcastAgentPollingIfChanged();
  return entry.event;
}

function recordGenerateDelivery(entry) {
  const event = entry?.event;
  if (!event || event.type !== 'generate' || event.generationReadyAt) return;
  const at = Date.now();
  entry.event = state.pendingDispatchAuth.sign({ ...event, generationReadyAt: at });
  state.sessionStore?.appendEvent(entry.event);
  recordAgentPhase(event.id, 'generation_ready', { at });
}

async function prepareGenerateEventForLease(entry) {
  const event = entry?.event;
  if (!event || event.type !== 'generate' || event.scaffoldAttempted) return;

  recordAgentPhase(event.id, 'picked_up');
  recordAgentPhase(event.id, 'scaffolding');
  const result = await runGenerationPreflight(event, {
    cwd: process.cwd(),
    scriptsDir: __dirname,
  });
  entry.event = state.pendingDispatchAuth.sign({
    ...event,
    scaffoldAttempted: true,
    scaffoldDurationMs: result.durationMs ?? null,
    ...(result.ok ? { scaffold: result.scaffold } : { scaffoldError: result.error || result.reason }),
  });
  state.sessionStore?.appendEvent(entry.event);
  recordAgentPhase(event.id, result.ok ? 'source_ready' : 'scaffold_fallback', {
    durationMs: result.durationMs ?? null,
    previewMode: result.scaffold?.previewMode || 'source',
  });
}

function recordAgentPhase(id, phase, details = {}) {
  if (!id) return;
  const event = {
    type: 'agent_phase',
    id,
    phase,
    at: Date.now(),
    ...details,
  };
  state.sessionStore?.appendEvent(event);
  broadcast({ type: 'agent_phase', id, phase, at: event.at,
    ...(Number.isFinite(event.durationMs) ? { durationMs: event.durationMs } : {}) });
}

/**
 * Detect a browser that missed the generation `done` broadcast.
 *
 * The preflight no longer writes the scaffold into source for source-preview
 * targets (the agent writes wrapper + variants in one atomic edit), so the old
 * scaffold-write full-reload that opened the "stranded at 0/N" race is gone.
 * This recovery stays as defense in depth: any framework reload that drops the
 * agent's variant write + `done` while the browser is mid-reload leaves the new
 * page in GENERATING at 0/N. That resumed page always checkpoints
 * (`browser_resumed`), so a checkpoint claiming "still generating, variants
 * missing" for a session whose generation already completed is direct
 * evidence of the miss. Rebuild the `done` payload from the snapshot so the
 * caller can re-broadcast it; the browser's done handler is idempotent and
 * falls back to injecting variants from source.
 *
 * Keys on the store's monotone `generationCompletedAt`, not `phase` — the
 * behind checkpoint itself regresses `phase` to `generating`, and a browser
 * that misses the redelivered `done` too (another reload) must still trigger
 * redelivery from its next checkpoint.
 */
function detectMissedGenerationCompletion(event) {
  if (!event?.id || event.type !== 'checkpoint') return null;
  if (event.phase !== 'generating') return null;
  if (!variantCountLooksBehind(event.arrivedVariants, event.expectedVariants)) return null;
  if (!state.sessionStore) return null;
  let snapshot = null;
  try {
    snapshot = state.sessionStore.getSnapshot(event.id);
  } catch {
    return null;
  }
  return missedCompletionFromSnapshot(snapshot);
}

function variantCountLooksBehind(arrivedValue, expectedValue) {
  const arrived = Number(arrivedValue) || 0;
  const expected = Number(expectedValue) || 0;
  return arrived <= 0 || (expected > 0 && arrived < expected);
}

function missedCompletionFromSnapshot(snapshot) {
  if (!snapshot?.id || !snapshot.generationCompletedAt) return null;
  if (snapshot.generationCanceled) return null;
  // Accept/discard already underway: the browser is no longer waiting on
  // generation, and a late `done` there would collide with teardown.
  if (GENERATION_FENCED_PHASES.has(snapshot.phase)) return null;
  const safeFiles = pageSafeFileMetadata({
    file: snapshot.publishedSourceFile || snapshot.publishedPreviewFile,
    sourceFile: snapshot.publishedSourceFile,
    previewFile: snapshot.publishedPreviewFile,
    previewMode: snapshot.publishedPreviewMode,
  });
  const file = safeFiles.file;
  if (!file) return null;
  return {
    type: 'done',
    id: snapshot.id,
    ...safeFiles,
    redelivered: true,
  };
}

function recordGenerationCheckpoint(event) {
  if (!event?.id || event.type !== 'checkpoint') return;
  if (generationIsFenced(event.id)) return;
  // Only checkpoints that report a change in variant availability are
  // generation progress. The browser also checkpoints for durability on Tune
  // slider drags, resumes, and anchor recovery; treating those as progress
  // echoed `variant_progress` straight back to the browser that sent it, which
  // remounts the component preview mid-drag (reverting the user's live param
  // edit and detaching the popover's element), and permanently latched the
  // *_reviewable phases from the wrong trigger, corrupting generation timings.
  if (!VARIANT_PROGRESS_CHECKPOINT_REASONS.has(event.reason)) return;
  const arrived = Number(event.arrivedVariants) || 0;
  const expected = Number(event.expectedVariants) || 0;
  if (arrived <= 0 || expected <= 0) return;
  const safeFiles = pageSafeFileMetadata({
    file: event.previewFile || event.file,
    sourceFile: event.sourceFile,
    previewFile: event.previewFile || event.file,
    previewMode: event.previewMode || 'source',
  });
  const previewFile = safeFiles.previewFile;
  if (previewFile) {
    broadcast({
      type: 'variant_progress',
      id: event.id,
      ...safeFiles,
      arrivedVariants: arrived,
      expectedVariants: expected,
      publicationKind: event.publicationKind || 'variants',
    });
  }
  const details = {
    arrivedVariants: arrived,
    expectedVariants: expected,
    checkpointReason: event.reason || null,
  };
  const at = Date.now();
  if (!generationPhaseAlreadyRecorded(event.id, 'first_reviewable')) {
    recordAgentPhase(event.id, 'first_reviewable', { ...details, at });
  }
  if (arrived >= 2 && expected >= 3 && !generationPhaseAlreadyRecorded(event.id, 'second_reviewable')) {
    recordAgentPhase(event.id, 'second_reviewable', { ...details, at });
  }
  if (arrived >= expected && !generationPhaseAlreadyRecorded(event.id, 'all_variants_ready')) {
    recordAgentPhase(event.id, 'all_variants_ready', { ...details, at });
  }
}

function pageCheckpointForJournal(msg, snapshot) {
  const expected = Number(snapshot?.expectedVariants) || 0;
  const reportedArrived = Number(msg.arrivedVariants) || 0;
  // Browser revisions are untrusted. Assign the journal's next revision here,
  // so a forged huge number cannot permanently stale legitimate checkpoints.
  const currentRevision = Number(snapshot?.browserCheckpointRevision ?? snapshot?.checkpointRevision) || 0;
  return {
    type: 'checkpoint',
    id: msg.id,
    revision: currentRevision + 1,
    revisionDomain: 'browser',
    owner: typeof msg.owner === 'string' ? msg.owner.slice(0, 64) : undefined,
    reason: CHECKPOINT_REASON_SET.has(msg.reason) ? msg.reason : undefined,
    arrivedVariants: Math.max(0, Math.min(expected, reportedArrived)),
    expectedVariants: expected,
    visibleVariant: Number.isInteger(msg.visibleVariant) && msg.visibleVariant >= 0 && msg.visibleVariant <= expected
      ? msg.visibleVariant : undefined,
    paramValues: msg.paramValues,
    // File metadata from a page is untrusted. Only agent-published paths may
    // enter the journal or drive preview/progress reads.
    sourceFile: snapshot?.publishedSourceFile || undefined,
    previewFile: snapshot?.publishedPreviewFile || undefined,
    previewMode: snapshot?.publishedPreviewMode || undefined,
  };
}

function pageTelemetryJournalBytes(id) {
  const roots = [state.sessionStore?.rootDir].filter(Boolean);
  let bytes = 0;
  for (const root of roots) {
    try { bytes = Math.max(bytes, fs.statSync(path.join(root, id + '.jsonl')).size); }
    catch (error) { if (error?.code !== 'ENOENT') throw error; }
  }
  return bytes;
}

function generationIsFenced(id) {
  if (!state.sessionStore || !id) return false;
  try {
    const snapshot = state.sessionStore.getSnapshot(id, { includeCompleted: true });
    return snapshot?.generationCanceled === true;
  } catch {
    return false;
  }
}

function generationPhaseAlreadyRecorded(id, phase) {
  if (!state.sessionStore) return false;
  try {
    const snapshot = state.sessionStore.getSnapshot(id, { includeCompleted: true });
    return !!snapshot?.generationTimings?.[phase];
  } catch {
    return false;
  }
}

function acknowledgePendingEvent(id, sourceEventType) {
  if (!id) return false;
  const idx = state.pendingEvents.findIndex((entry) => (
    entry.event?.id === id
    && (!sourceEventType || entry.event?.type === sourceEventType)
  ));
  if (idx === -1) return false;
  const acknowledged = state.pendingEvents[idx].event;
  state.pendingEvents.splice(idx, 1);
  scheduleLeaseFlush();
  broadcastAgentPollingIfChanged();
  return acknowledged;
}

function releasePendingEvent(id, sourceEventType) {
  const entry = state.pendingEvents.find((item) => (
    item.event?.id === id
    && (!sourceEventType || item.event?.type === sourceEventType)
  ));
  if (!entry) return null;
  entry.leaseUntil = 0;
  scheduleLeaseFlush();
  return entry.event;
}

function retirePendingGeneration(id) {
  if (!id) return 0;
  let retired = 0;
  for (let index = state.pendingEvents.length - 1; index >= 0; index -= 1) {
    const event = state.pendingEvents[index]?.event;
    if (event?.id !== id || event.type !== 'generate') continue;
    state.pendingEvents.splice(index, 1);
    retired += 1;
  }
  if (retired > 0) {
    scheduleLeaseFlush();
    broadcastAgentPollingIfChanged();
  }
  return retired;
}

function findPendingEventById(id, sourceEventType) {
  if (!id) return null;
  const entry = state.pendingEvents.find((item) => (
    item.event?.id === id
    && (!sourceEventType || item.event?.type === sourceEventType)
  ));
  return entry?.event || null;
}

function summarizePendingEventForStatus(entry) {
  const event = entry.event || {};
  const summary = {
    id: event.id,
    type: event.type,
    leased: isLeased(entry),
    leaseUntil: entry.leaseUntil || null,
  };
  if (event.type === 'manual_edit_apply') {
    summary.pageUrl = event.pageUrl || null;
    summary.chunk = event.chunk || null;
    summary.repair = event.repair || null;
    summary.evidencePath = event.evidencePath || null;
    summary.agentAction = event.agentAction || manualApply.buildAgentAction(event);
    summary.manualApplySummary = manualApply.summarizeEvent(event, manualApply.getDeferred(event.id)?.batch || event.batch);
  }
  return summary;
}

function summarizeActiveSessionForClient(snapshot = {}, { pageSafe = false } = {}) {
  let safePageUrl = null;
  if (pageSafe && typeof snapshot.pageUrl === 'string' && snapshot.pageUrl.length <= 2048
      && !/[\x00-\x1f\x7f<>{}]/.test(snapshot.pageUrl)) {
    try {
      const candidate = new URL(snapshot.pageUrl, 'http://localhost');
      if (candidate.pathname.length <= 512) safePageUrl = candidate.pathname;
    } catch { /* legacy journal supplied malformed URL */ }
  }
  const files = pageSafe ? pageSafeFileMetadata({
    sourceFile: snapshot.sourceFile,
    previewFile: snapshot.previewFile,
    previewMode: snapshot.previewMode,
  }) : snapshot;
  return {
    id: snapshot.id,
    phase: pageSafe ? (PAGE_SAFE_SESSION_PHASES.has(snapshot.phase) ? snapshot.phase : 'agent_error') : snapshot.phase,
    pageUrl: pageSafe ? safePageUrl : (snapshot.pageUrl ?? null),
    sourceFile: files.sourceFile ?? null,
    previewFile: files.previewFile ?? null,
    previewMode: files.previewMode ?? null,
    expectedVariants: snapshot.expectedVariants ?? 0,
    arrivedVariants: snapshot.arrivedVariants ?? 0,
    visibleVariant: snapshot.visibleVariant ?? null,
    checkpointRevision: snapshot.checkpointRevision ?? 0,
    browserCheckpointRevision: snapshot.browserCheckpointRevision ?? snapshot.checkpointRevision ?? 0,
    publicationCheckpointRevision: snapshot.publicationCheckpointRevision ?? 0,
    // Cross-session parameter values may contain private page data from a
    // legacy journal. A browser with its own local state retains its values;
    // another tab safely resumes with defaults.
    paramValues: pageSafe ? {} : (snapshot.paramValues || {}),
    generationPhase: pageSafe
      ? (AGENT_PHASE_SET.has(snapshot.generationPhase) ? snapshot.generationPhase : null)
      : (snapshot.generationPhase ?? null),
    generationCompletedAt: snapshot.generationCompletedAt ?? null,
    generationCanceled: snapshot.generationCanceled === true,
    cancelReason: snapshot.cancelReason ?? null,
    // Render truth, so a browser with no localStorage can rehydrate to the
    // same comparison the server already knows about.
    mountedVariants: pageSafe
      ? (Array.isArray(snapshot.mountedVariants) ? snapshot.mountedVariants : [])
        .filter((variant) => Number.isInteger(variant) && variant >= 1 && variant <= 999).slice(-100)
      : (Array.isArray(snapshot.mountedVariants) ? snapshot.mountedVariants : []),
    mountFailures: pageSafe
      ? (Array.isArray(snapshot.mountFailures) ? snapshot.mountFailures : [])
        .filter((failure) => Number.isInteger(failure?.variant) && failure.variant >= 1 && failure.variant <= 999)
        .slice(-5).map((failure) => ({ variant: failure.variant,
          at: Number.isSafeInteger(failure.at) ? failure.at : null,
          error: 'Variant failed to mount' }))
      : (Array.isArray(snapshot.mountFailures) ? snapshot.mountFailures : []),
    renderState: pageSafe
      ? (['pending', 'mounted', 'failed'].includes(snapshot.renderState) ? snapshot.renderState : null)
      : (snapshot.renderState ?? null),
  };
}

function activeSessionSummaries({ pageSafe = false } = {}) {
  if (!state.sessionStore) return [];
  return state.sessionStore.listActiveSessions().map((snapshot) => summarizeActiveSessionForClient(snapshot, { pageSafe }));
}

function scheduleLeaseFlush() {
  if (state.leaseTimer) {
    clearTimeout(state.leaseTimer);
    state.leaseTimer = null;
  }
  const now = Date.now();
  const nextLeaseUntil = state.pendingEvents
    .map((entry) => entry.leaseUntil || 0)
    .filter((leaseUntil) => leaseUntil > now)
    .sort((a, b) => a - b)[0];
  if (!nextLeaseUntil) return;
  state.leaseTimer = setTimeout(() => {
    state.leaseTimer = null;
    flushPendingPolls();
    broadcastAgentPollingIfChanged();
  }, Math.max(0, nextLeaseUntil - now + POLL_LEASE_EXPIRY_TIMER_GRACE_MS));
}

function flushPendingPolls() {
  let changed = false;
  while (state.pendingPolls.length > 0) {
    let pollIndex = -1;
    let entry = null;
    for (let index = 0; index < state.pendingPolls.length; index += 1) {
      const candidate = findAvailablePendingEvent(Date.now(), state.pendingPolls[index].types);
      if (!candidate) continue;
      pollIndex = index;
      entry = candidate;
      break;
    }
    if (!entry) {
      scheduleLeaseFlush();
      broadcastAgentPollingIfChanged();
      return;
    }
    const [poll] = state.pendingPolls.splice(pollIndex, 1);
    // leaseEvent is async (it may scaffold source), but it claims the entry
    // synchronously, so the next loop iteration will not re-select it. Resolve
    // the poll when the lease settles rather than awaiting here, so one slow
    // scaffold never delays the other parked polls. On the exceptional failure
    // path, answer `timeout` so the agent re-polls; the claim stays until the
    // lease expires, which keeps a deterministic failure from hot-looping.
    leaseEvent(entry, poll.leaseMs).then(poll.resolve, (error) => {
      console.error('[live] lease failed for ' + (entry.event?.id || 'unknown') + ': ' + (error?.message || error));
      poll.resolve({ type: 'timeout' });
    });
    changed = true;
  }
  scheduleLeaseFlush();
  if (changed) broadcastAgentPollingIfChanged();
}

function isLeased(entry) {
  return !!(entry?.leaseUntil && entry.leaseUntil > Date.now());
}

function agentPollingConnected() {
  // A leased event only proves that a poll returned once. The foreground task
  // may have ended immediately afterward, so only an actively waiting poll is
  // evidence that steering can wake the task right now.
  return state.pendingPolls.length > 0;
}

function broadcastAgentPollingIfChanged() {
  const connected = agentPollingConnected();
  if (state.lastAgentPollingBroadcast === connected) return;
  state.lastAgentPollingBroadcast = connected;
  broadcast({ type: 'agent_polling', connected });
}

/** Push a message to all connected SSE clients. */
function broadcast(msg) {
  const data = 'data: ' + JSON.stringify(msg) + '\n\n';
  for (const res of state.sseClients) {
    try { res.write(data); } catch { /* client gone */ }
  }
}

function recordManualEditActivity(type, details = {}) {
  const entry = {
    seq: state.nextManualEditSeq++,
    type,
    ts: new Date().toISOString(),
    ...details,
  };
  state.manualEditActivity = entry;
  if (DEBUG_MANUAL_EDIT_EVENTS) {
    try {
      const filePath = path.join(getLivePrivateDir(process.cwd()), 'manual-edit-events.jsonl');
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
      fs.appendFileSync(filePath, JSON.stringify(entry) + '\n');
    } catch {
      /* diagnostics are best-effort; never block live mode on observability */
    }
  }
  broadcast(pageSafeManualEditActivity(entry));
  return entry;
}

function getManualEditStatus() {
  try {
    const { totalCount, perPage } = countPendingByPage(process.cwd());
    return { totalCount, perPage, lastActivity: state.manualEditActivity };
  } catch (err) {
    return {
      totalCount: null,
      perPage: {},
      lastActivity: state.manualEditActivity,
      error: err.message,
    };
  }
}

// ---------------------------------------------------------------------------
// Load scripts
// ---------------------------------------------------------------------------

function loadBrowserScripts() {
  // Detection script: prefer the skill-bundled detector, then fall back to
  // source/npm package locations for local development and older installs.
  // This one IS cached — detect.js rarely changes during a session.
  const detectPaths = [
    path.join(__dirname, 'detector', 'detect-antipatterns-browser.js'),
    path.join(__dirname, '..', '..', 'cli', 'engine', 'detect-antipatterns-browser.js'),
    path.join(__dirname, '..', '..', '..', '..', 'cli', 'engine', 'detect-antipatterns-browser.js'),
    path.join(process.cwd(), 'node_modules', 'impeccable', 'cli', 'engine', 'detect-antipatterns-browser.js'),
  ];
  let detectScript = '';
  for (const p of detectPaths) {
    try { detectScript = fs.readFileSync(p, 'utf-8'); break; } catch { /* try next */ }
  }

  // Browser script parts: DO NOT cache. Return paths so the /live.js handler
  // can re-read every part on each request. Editing browser code during
  // iteration should land on the next tab reload, not require a server restart.
  const liveScriptParts = resolveLiveBrowserScriptParts(__dirname);
  try {
    assertLiveBrowserScriptParts(liveScriptParts);
  } catch (err) {
    process.stderr.write('Error: ' + err.message + '\n');
    process.exit(1);
  }

  return { detectScript, liveScriptParts };
}

function hasProjectContext() {
  // PRODUCT.md carries brand voice / anti-references — that's what determines
  // whether variants are brand-aware. DESIGN.md (visual tokens) is a separate
  // concern, surfaced by the design panel's own empty state.
  return !!resolveProjectContext().hasProduct;
}

function readAuthorizedContextFile(filePath, roots) {
  if (!filePath) return null;
  for (const root of [...new Set(roots.filter(Boolean).map((value) => path.resolve(value)))]) {
    try {
      const authorized = resolvePathInside(root, filePath, { kind: 'file' });
      return {
        path: authorized,
        stat: fs.lstatSync(authorized),
        content: readFileInside(root, authorized, { encoding: 'utf8', maxBytes: MAX_LIVE_JSON_BYTES }),
      };
    } catch (error) {
      if (error?.code === 'PATH_OUTSIDE_ROOT') continue;
      return null;
    }
  }
  return null;
}

// Strict loopback-origin test for CORS. Parses the Origin as a URL (never a
// substring match, so `http://localhost.evil.com` and `http://127.0.0.1.evil.com`
// fail) and accepts only http/https on localhost, 127.0.0.1, or the IPv6 loopback.
function isLoopbackOrigin(origin) {
  if (typeof origin !== 'string' || origin.length === 0) return false;
  let parsed;
  try { parsed = new URL(origin); } catch { return false; }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
  const host = parsed.hostname.toLowerCase();
  return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]';
}

const PAGE_CORS_PATHS = new Set([
  '/live.js', '/events', '/annotation',
  '/page-status', '/page-preview', '/page-manual-edit-count',
]);

function isPageCorsRequest(req, pathname) {
  if (/^\/page-approval\/[0-9a-f-]{36}$/.test(pathname)) return true;
  if (pathname === '/manual-edit-stash') {
    const method = req.method === 'OPTIONS' ? req.headers['access-control-request-method'] : req.method;
    return method === 'POST';
  }
  return PAGE_CORS_PATHS.has(pathname);
}

// HTTP request handler
// ---------------------------------------------------------------------------

function createRequestHandler({ detectScript, liveScriptParts }) {
  return (req, res) => {
    // Any web page can make a browser send a target such as `//[`, which parses
    // as an authority and throws. Unguarded, that exception ended the helper
    // before any auth check.
    let url;
    try { url = new URL(req.url, liveHelperBase(state.port)); }
    catch { res.writeHead(400); res.end('Bad request'); return; }
    // The inspected page owns only a page-scoped capability. It may come from
    // a localhost dev server or a non-loopback alias, but controller responses
    // must never be CORS-readable by either. Same-origin controller fetches
    // need no CORS headers.
    const origin = req.headers.origin;
    const pageCors = isPageCorsRequest(req, url.pathname);
    if (origin && pageCors
        && (isLoopbackOrigin(origin)
          || tokenMatches(url.searchParams.get('token'), state.pageToken))) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
    }
    if (pageCors) {
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Impeccable-Token');
    }
    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

    const p = url.pathname;

    if (p === '/control' && req.method === 'GET') {
      const nonce = randomUUID().replaceAll('-', '');
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer',
        'X-Frame-Options': 'DENY',
        'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; img-src blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
      });
      res.end(renderControlUi(nonce));
      return;
    }

    if (p === '/control/approvals' && req.method === 'GET') {
      if (!requireLivePostAuth(req, res)) return;
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ approvals: [...state.pageApprovals.values()]
        .filter((approval) => !approval.dispatching)
        .map(({ id, msg, createdAt }) => ({ id, msg, createdAt })),
      capacity: MAX_PENDING_PAGE_APPROVALS }));
      return;
    }
    const approvalMatch = /^\/control\/approvals\/([0-9a-f-]{36})\/(approve|reject)$/.exec(p);
    if (approvalMatch && req.method === 'POST') {
      if (!requireLivePostAuth(req, res)) return;
      void resolvePageApproval(approvalMatch[1], approvalMatch[2]).then((found) => {
        res.writeHead(found ? 200 : 404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(found ? { ok: true } : { error: 'approval_not_found' }));
      });
      return;
    }

    const controllerAnnotationMatch = /^\/control\/annotation\/([A-Za-z0-9_-]{1,64})$/.exec(p);
    if (controllerAnnotationMatch && req.method === 'GET') {
      if (!requireLivePostAuth(req, res)) return;
      const eventId = controllerAnnotationMatch[1];
      if (!state.annotationSizes.has(eventId)) {
        res.writeHead(404); res.end('Annotation not found'); return;
      }
      try {
        const png = readFileInside(state.sessionDir, eventId + '.png', {
          encoding: null, maxBytes: MAX_ANNOTATION_BYTES,
        });
        res.writeHead(200, {
          'Content-Type': 'image/png', 'Cache-Control': 'no-store',
          'X-Content-Type-Options': 'nosniff',
          'Content-Security-Policy': "default-src 'none'; sandbox",
        });
        res.end(png);
      } catch {
        res.writeHead(404); res.end('Annotation not found');
      }
      return;
    }

    const controllerEvidenceMatch = /^\/control\/manual-edit-evidence\/([A-Za-z0-9_-]{1,128})$/.exec(p);
    if (controllerEvidenceMatch && req.method === 'GET') {
      if (!requireLivePostAuth(req, res)) return;
      try {
        const body = readFileInside(manualApplyEvidenceDir(process.cwd()), `${controllerEvidenceMatch[1]}.json`, {
          encoding: 'utf8', maxBytes: MAX_MANUAL_APPLY_EVIDENCE_BYTES,
        });
        res.writeHead(200, {
          'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
          'X-Content-Type-Options': 'nosniff',
          'Content-Security-Policy': "default-src 'none'; sandbox",
        });
        res.end(body);
      } catch (error) {
        res.writeHead(error?.code === 'FILE_TOO_LARGE' ? 413 : 404);
        res.end(error?.code === 'FILE_TOO_LARGE' ? 'Evidence exceeds the authorized byte budget' : 'Evidence not found');
      }
      return;
    }

    // --- Scripts ---
    if (p === '/live.js') {
      // The URL and body are both readable by arbitrary inspected-page JS.
      // They may carry the page capability, never the controller credential.
      if (!requireQueryToken(url, res, state.pageToken)) return;
      // Re-read from disk each request so edits to live-browser.js land on
      // the next tab reload. No-store headers prevent browser caching across
      // sessions — during iteration, a cached old script silently breaks
      // every subsequent session.
      let parts;
      try {
        parts = readLiveBrowserScriptParts(liveScriptParts);
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end('Error reading live browser scripts: ' + err.message);
        return;
      }
      const body = assembleLiveBrowserScript({
        token: state.pageToken,
        port: state.port,
        vocabulary: LIVE_COMMANDS,
        commandPrefix: IMPECCABLE_COMMAND_PREFIX,
        appRoot: process.cwd(),
        parts,
      });
      res.writeHead(200, {
        'Content-Type': 'application/javascript',
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
        'Pragma': 'no-cache',
      });
      res.end(body);
      return;
    }
    if (p === '/detect.js' || p === '/') {
      if (!detectScript) { res.writeHead(404); res.end('Not available'); return; }
      res.writeHead(200, { 'Content-Type': 'application/javascript' });
      res.end(detectScript);
      return;
    }

    // --- Vendored modern-screenshot (UMD build) ---
    // Lazy-loaded by live.js when the user clicks Go; exposes
    // window.modernScreenshot.domToBlob(...) for capture.
    if (p === '/modern-screenshot.js') {
      const vendorPath = path.join(__dirname, 'modern-screenshot.umd.js');
      try {
        res.writeHead(200, {
          'Content-Type': 'application/javascript',
          'Cache-Control': 'public, max-age=31536000, immutable',
        });
        res.end(fs.readFileSync(vendorPath));
      } catch {
        res.writeHead(404); res.end('Vendor script not found');
      }
      return;
    }

    // --- Annotation upload (browser → server, raw PNG body) ---
    // Client generates the eventId, POSTs the PNG, then POSTs the generate
    // event with screenshotPath already set. Keeps bytes out of the SSE/poll
    // bridge and preserves the "one shot from the user's POV" UX.
    if (p === '/annotation' && req.method === 'POST') {
      if (!requirePagePostAuth(req, res)) return;
      const eventId = url.searchParams.get('eventId');
      if (!eventId || !/^[A-Za-z0-9_-]{1,64}$/.test(eventId)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid eventId' }));
        return;
      }
      if (!state.sessionDir) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Session dir unavailable' }));
        return;
      }
      readBoundedBody(req, {
        maxBytes: MAX_ANNOTATION_BYTES,
        timeoutMs: 10_000,
        contentType: 'image/png',
      }).then((body) => {
        const absPath = path.join(state.sessionDir, eventId + '.png');
        if (state.annotationSizes.has(eventId)) {
          res.writeHead(409, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'annotation_already_uploaded' }));
          return;
        }
        if (state.annotationSizes.size >= MAX_ANNOTATION_FILES
            || state.annotationBytes + body.length > MAX_ANNOTATION_TOTAL_BYTES) {
          res.writeHead(429, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'annotation_budget_exceeded' }));
          return;
        }
        try {
          atomicWriteFileInside(process.cwd(), absPath, body, { encoding: null, mode: 0o600 });
        } catch (err) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Write failed: ' + err.message }));
          return;
        }
        state.annotationSizes.set(eventId, body.length);
        state.annotationBytes += body.length;
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, path: absPath }));
      }).catch((error) => sendHttpInputError(req, res, error));
      return;
    }

    // --- Health ---
    if (p === '/status') {
      const token = url.searchParams.get('token');
      if (!tokenMatches(token, state.token)) { res.writeHead(401, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: 'Unauthorized' })); return; }
      const sessions = activeSessionSummaries();
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({
        status: 'ok',
        port: state.port,
        connectedClients: state.sseClients.size,
        pendingEvents: state.pendingEvents.map((entry) => summarizePendingEventForStatus(entry)),
        agentPolling: agentPollingConnected(),
        activeSessions: sessions,
        manualEdits: getManualEditStatus(),
      }));
      return;
    }

    if (p === '/page-status' && req.method === 'GET') {
      if (!requireQueryToken(url, res, state.pageToken)) return;
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ agentPolling: agentPollingConnected() }));
      return;
    }

    if (p === '/page-manual-edit-count' && req.method === 'GET') {
      if (!requireQueryToken(url, res, state.pageToken)) return;
      const pageUrl = url.searchParams.get('pageUrl') || '';
      const { totalCount, perPage } = countPendingByPage(process.cwd());
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ count: perPage[pageUrl] || 0, totalCount }));
      return;
    }

    if (p === '/page-preview' && req.method === 'GET') {
      if (!requireQueryToken(url, res, state.pageToken)) return;
      // A source-derived wrapper or Svelte manifest can contain expressions,
      // comments, and attributes never rendered in the inspected DOM. The
      // page is untrusted, so no source-derived recovery bytes leave here.
      res.writeHead(410, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'none'; sandbox",
      });
      res.end('Source recovery is disabled for inspected pages. Wait for HMR or reload the page.');
      return;
    }

    const pageApprovalMatch = /^\/page-approval\/([0-9a-f-]{36})$/.exec(p);
    if (pageApprovalMatch && req.method === 'GET') {
      if (!requireQueryToken(url, res, state.pageToken)) return;
      const id = pageApprovalMatch[1];
      const pending = state.pageApprovals.has(id);
      const outcome = state.pageApprovalOutcomes.get(id);
      res.writeHead(pending ? 202 : outcome ? 200 : 404, {
        'Content-Type': 'application/json', 'Cache-Control': 'no-store',
      });
      res.end(JSON.stringify(pending ? { status: 'pending' }
        : outcome ? { status: 'settled', eventStatus: outcome.status, body: outcome.body }
          : { error: 'approval_not_found' }));
      return;
    }

    if (p === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: 'ok', port: state.port, mode: 'variant',
        hasProjectContext: hasProjectContext(),
        connectedClients: state.sseClients.size,
      }));
      return;
    }

    // --- Design system (unified v2 response) + raw ---
    //   /design-system.json    returns both parsed DESIGN.md and .impeccable/design.json
    //                          sidecar when present. Panel merges them:
    //                            { present, parsed, sidecar, hasMd, hasSidecar,
    //                              mdNewerThanJson, parseError?, sidecarError? }
    //                          - parsed: output of parseDesignMd (frontmatter
    //                            + the canonical sections) when DESIGN.md exists.
    //                          - sidecar: .impeccable/design.json contents when present.
    //                            Expected shape: schemaVersion 2, carrying
    //                            extensions + components + narrative.
    //   /design-system/raw     returns DESIGN.md markdown verbatim
    if (p === '/design-system.json' || p === '/design-system/raw') {
      const token = url.searchParams.get('token');
      if (!tokenMatches(token, state.token)) { res.writeHead(401); res.end('Unauthorized'); return; }

      const projectContext = resolveProjectContext();
      const mdPath = projectContext.resolvedDesignPath;
      const jsonPath = resolveDesignSidecarPath(process.cwd(), projectContext.designContextDir || projectContext.contextDir) || getDesignSidecarPath(process.cwd());
      const authorizedRoots = [
        process.cwd(),
        projectContext.contextDir,
        projectContext.designContextDir,
        LIVE_ROOTS?.contextRoot,
      ];
      const mdFile = readAuthorizedContextFile(mdPath, authorizedRoots);
      const jsonFile = readAuthorizedContextFile(jsonPath, authorizedRoots);

      if (p === '/design-system/raw') {
        if (!mdFile) { res.writeHead(404); res.end('Not found'); return; }
        res.writeHead(200, {
          'Content-Type': 'text/plain; charset=utf-8',
          'Cache-Control': 'no-store',
          'X-Content-Type-Options': 'nosniff',
          'Content-Security-Policy': "default-src 'none'; sandbox",
        });
        res.end(mdFile.content);
        return;
      }

      if (!mdFile && !jsonFile) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ present: false }));
        return;
      }

      const response = {
        present: true,
        hasMd: !!mdFile,
        hasSidecar: !!jsonFile,
        mdNewerThanJson: !!(mdFile && jsonFile && mdFile.stat.mtimeMs > jsonFile.stat.mtimeMs + 1000),
      };

      if (mdFile) {
        try {
          response.parsed = parseDesignMd(mdFile.content);
        } catch (err) {
          response.parseError = err.message;
        }
      }

      if (jsonFile) {
        try {
          response.sidecar = JSON.parse(jsonFile.content);
        } catch (err) {
          response.sidecarError = 'Failed to parse .impeccable/design.json: ' + err.message;
        }
      }

      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(response));
      return;
    }

    // --- Trusted-controller source reader ---
    if (p === '/source') {
      const token = url.searchParams.get('token');
      if (!tokenMatches(token, state.token)) { res.writeHead(401); res.end('Unauthorized'); return; }
      const filePath = url.searchParams.get('path');
      if (!filePath || filePath.includes('..')) { res.writeHead(400); res.end('Bad path'); return; }
      const lexicalPath = path.resolve(process.cwd(), filePath);
      if (!isAllowedLiveSource(lexicalPath)) { res.writeHead(403); res.end('Forbidden'); return; }
      let content;
      try { content = readFileInside(process.cwd(), filePath, { encoding: 'utf8', maxBytes: MAX_LIVE_JSON_BYTES }); }
      catch (error) {
        const status = ['PATH_OUTSIDE_ROOT', 'SYMLINK_REJECTED'].includes(error?.code) ? 403 : 404;
        res.writeHead(status); res.end(status === 403 ? 'Forbidden' : 'File not found'); return;
      }
      res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'none'; sandbox",
      });
      res.end(content);
      return;
    }

    // --- SSE: server→browser push (replaces WebSocket) ---
    if (p === '/events' && req.method === 'GET') {
      const token = url.searchParams.get('token');
      if (!tokenMatches(token, state.pageToken)) { res.writeHead(401); res.end('Unauthorized'); return; }
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });
      res.write('data: ' + JSON.stringify({
        type: 'connected',
        hasProjectContext: hasProjectContext(),
        agentPolling: agentPollingConnected(),
        activeSessions: activeSessionSummaries({ pageSafe: true }),
      }) + '\n\n');

      state.sseClients.add(res);

      // Keepalive: SSE comment every 30s prevents silent connection drops.
      const heartbeat = setInterval(() => {
        try { res.write(': keepalive\n\n'); } catch { clearInterval(heartbeat); }
      }, SSE_HEARTBEAT_INTERVAL);

      req.on('close', () => {
        clearInterval(heartbeat);
        state.sseClients.delete(res);
        // A page can close or navigate itself. That must not dispatch an
        // agent `exit` without a trusted-controller decision.
      });
      return;
    }

    if (manualEditRoutes(req, res, url)) return;

    // --- Browser→server events (replaces WebSocket messages) ---
    if (p === '/events' && req.method === 'POST') {
      const bearer = requestToken(req, 'x-impeccable-token');
      const controller = tokenMatches(bearer, state.token);
      const page = tokenMatches(bearer, state.pageToken);
      if (!controller && !page) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Unauthorized' }));
        return;
      }
      // A browser from the inspected page must never be able to replay a
      // controller credential if one is accidentally exposed elsewhere.
      if (controller && req.headers.origin && !isSameControllerOrigin(req)) {
        res.writeHead(403, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'controller_origin_required' }));
        return;
      }
      readBoundedJson(req, { maxBytes: MAX_LIVE_JSON_BYTES }).then((msg) => {
        // Defense in depth: manual copy edits must use the staged stash/apply
        // endpoints. The direct Save event path is disabled in the browser.
        if (msg.type === 'manual_edits') {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'manual_edits must POST to /manual-edit-stash, not /events' }));
          return;
        }
        if (msg.type === 'manual_edit_apply') {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'manual_edit_apply is disabled; use /manual-edit-stash then /manual-edit-commit' }));
          return;
        }
        const error = validateEvent(msg);
        if (error) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error }));
          return;
        }
        if (page) {
          if (PAGE_ACTION_TYPES.has(msg.type)) {
            if (msg.type === 'generate' && msg.screenshotPath) {
              const uploaded = state.annotationSizes.has(msg.id)
                ? path.join(state.sessionDir, msg.id + '.png') : null;
              if (msg.screenshotPath !== uploaded) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'screenshot_not_uploaded_for_event' }));
                return;
              }
            }
            queuePageApproval(res, msg);
            return;
          }
          if (!PAGE_TELEMETRY_TYPES.has(msg.type)) {
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'controller_action_required' }));
            return;
          }
        }
        if (msg.type === 'agent_phase') {
          recordAgentPhase(msg.id, msg.phase, {
            ...(Number.isFinite(msg.durationMs) ? { durationMs: msg.durationMs } : {}),
            owner: typeof msg.owner === 'string' ? msg.owner : undefined,
          });
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true }));
          return;
        }
        // Only the events that START a session may create its journal.
        // Everything else (checkpoints, mount acks, accept/discard) must
        // reference a session THIS store already knows: appendEvent creates a
        // journal for any id it is handed, so without this gate a browser
        // resuming another project's session from per-origin storage (two
        // apps sharing a localhost port) materializes a ghost session here
        // that keeps reattaching after every discard.
        if (msg.id && state.sessionStore
            && !SESSION_CREATING_EVENT_TYPES.has(msg.type)
            && !state.sessionStore.has(msg.id)) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'unknown_session', id: msg.id }));
          return;
        }
        let pageTelemetrySnapshot = null;
        if (page && PAGE_TELEMETRY_TYPES.has(msg.type)) {
          pageTelemetrySnapshot = state.sessionStore?.getSnapshot(msg.id);
          if (!pageTelemetrySnapshot || pageTelemetrySnapshot.generationCanceled
              || GENERATION_FENCED_PHASES.has(pageTelemetrySnapshot.phase)) {
            res.writeHead(410, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'session_not_active' }));
            return;
          }
          if (pageTelemetryJournalBytes(msg.id) >= MAX_PAGE_TELEMETRY_JOURNAL_BYTES) {
            res.writeHead(429, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'page_telemetry_budget_exceeded' }));
            return;
          }
          if (msg.type === 'checkpoint') {
            const storedRevision = Number(pageTelemetrySnapshot.browserCheckpointRevision
              ?? pageTelemetrySnapshot.checkpointRevision ?? 0);
            if (!Number.isSafeInteger(storedRevision) || storedRevision > 10_000_000) {
              res.writeHead(409, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'legacy_checkpoint_revision_poisoned',
                hint: 'End this legacy session and start a new one from the trusted controller.' }));
              return;
            }
            if (msg.paramValues !== undefined
                && Buffer.byteLength(JSON.stringify(msg.paramValues)) > MAX_PAGE_CHECKPOINT_PARAM_BYTES) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'checkpoint_params_too_large' }));
              return;
            }
            const now = Date.now();
            const lastAt = state.pageCheckpointLastAt.get(msg.id) || 0;
            const reportsNewVariant = CHECKPOINT_REASON_SET.has(msg.reason)
              && VARIANT_PROGRESS_CHECKPOINT_REASONS.has(msg.reason)
              && Number(msg.arrivedVariants) > Number(pageTelemetrySnapshot.arrivedVariants || 0);
            if (now - lastAt < PAGE_CHECKPOINT_MIN_INTERVAL_MS && !reportsNewVariant) {
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ ok: true, throttled: true }));
              return;
            }
            if (state.pageCheckpointLastAt.size >= 128 && !state.pageCheckpointLastAt.has(msg.id)) {
              state.pageCheckpointLastAt.delete(state.pageCheckpointLastAt.keys().next().value);
            }
            state.pageCheckpointLastAt.set(msg.id, now);
          } else {
            if (msg.variant > Number(pageTelemetrySnapshot.expectedVariants || 0)) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'variant_outside_session' }));
              return;
            }
            if (pageTelemetrySnapshot.mountedVariants?.includes(msg.variant)) {
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ ok: true, duplicate: true }));
              return;
            }
            // Mount acks are read-only telemetry; never journal arbitrary
            // extra fields from the page-token JSON object.
            msg = { type: 'variant_mounted', id: msg.id, variant: msg.variant,
              ...(typeof msg.url === 'string' ? { url: msg.url } : {}) };
          }
        }
        const missedCompletion = detectMissedGenerationCompletion(msg);
        if (page && msg.type === 'checkpoint') msg = pageCheckpointForJournal(msg, pageTelemetrySnapshot);
        if (controller && PERSISTED_PENDING_TYPES.has(msg.type)) {
          msg = state.pendingDispatchAuth.sign(msg);
        }
        if (state.sessionStore && msg.id) {
          try {
            state.sessionStore.appendEvent(msg);
          } catch (err) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'session_store_append_failed', message: err.message }));
            return;
          }
        }
        if (msg.type === 'accept' || msg.type === 'discard') {
          retirePendingGeneration(msg.id);
        }
        recordGenerationCheckpoint(msg);
        if (missedCompletion) broadcast(missedCompletion);
        if (msg.type === 'exit') {
          cleanupSvelteComponentSessionsBeforeExit();
        }
        // An ORPHANED discard is the browser reporting that the session's
        // wrapper no longer exists in source (edited or regenerated away).
        // There is no cleanup for an agent to perform, and asking one to run
        // the normal discard flow would just fail against the missing
        // scaffolding, so the server terminalizes the session itself and the
        // event stays out of the poll queue.
        const orphanedDiscard = msg.type === 'discard' && msg.orphaned === true;
        if (orphanedDiscard && state.sessionStore && msg.id) {
          try {
            state.sessionStore.appendEvent({ type: 'discarded', id: msg.id, orphaned: true });
          } catch { /* the discard_requested phase already left the resumable set */ }
        }
        // `variant_mounted` is the happy path: it is journaled above so the
        // snapshot carries render truth, but there is nothing for the agent to
        // do about it, so it stays out of the poll queue and off the SSE bus.
        // `variant_mount_failed` is the opposite: the agent published something
        // the browser could not render, and only the agent can fix it, so it
        // goes to the queue as a first-class event.
        if (msg.type !== 'checkpoint' && msg.type !== 'variant_mounted' && !orphanedDiscard) {
          enqueueEvent(msg);
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      }).catch((error) => sendHttpInputError(req, res, error));
      return;
    }

    // --- Stop ---
    if (p === '/stop' && req.method === 'POST') {
      if (!requireLivePostAuth(req, res)) return;
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('stopping');
      shutdown();
      return;
    }

    // --- Agent poll ---
    if (p === '/poll' && req.method === 'GET') {
      handlePollGet(req, res, url);
      return;
    }
    if (p === '/poll' && req.method === 'POST') {
      handlePollPost(req, res);
      return;
    }

    res.writeHead(404); res.end('Not found');
  };
}

// ---------------------------------------------------------------------------
// Agent poll endpoints (unchanged from WS version)
// ---------------------------------------------------------------------------

function parsePollTypes(value) {
  if (!value) return null;
  const types = String(value).split(',').map((type) => type.trim()).filter(Boolean);
  return types.length > 0 ? new Set(types) : null;
}

function handlePollGet(req, res, url) {
  const token = url.searchParams.get('token');
  if (!tokenMatches(token, state.token)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Unauthorized' }));
    return;
  }
  state.lastPollAt = Date.now();
  const timeout = parseInt(url.searchParams.get('timeout') || DEFAULT_POLL_TIMEOUT, 10);
  const leaseMs = parseInt(url.searchParams.get('leaseMs') || '30000', 10);
  const types = parsePollTypes(url.searchParams.get('types'));
  const available = findAvailablePendingEvent(Date.now(), types);
  if (available) {
    // Do not await inline: leaseEvent may scaffold source, and this handler runs
    // on the server's only thread. The client can disconnect during that window,
    // so check the socket before replying.
    leaseEvent(available, leaseMs).then((event) => {
      if (res.writableEnded || res.destroyed) return;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(event));
    }, (error) => {
      console.error('[live] lease failed for ' + (available.event?.id || 'unknown') + ': ' + (error?.message || error));
      if (res.writableEnded || res.destroyed) return;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ type: 'timeout' }));
    });
    return;
  }
  const poll = { resolve, leaseMs, types };
  const timer = setTimeout(() => {
    const idx = state.pendingPolls.indexOf(poll);
    if (idx !== -1) state.pendingPolls.splice(idx, 1);
    broadcastAgentPollingIfChanged();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ type: 'timeout' }));
  }, timeout);
  function resolve(event) {
    clearTimeout(timer);
    state.lastPollAt = Date.now();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(event));
  }
  state.pendingPolls.push(poll);
  broadcastAgentPollingIfChanged();
  scheduleLeaseFlush();
  req.on('close', () => {
    clearTimeout(timer);
    const idx = state.pendingPolls.indexOf(poll);
    if (idx !== -1) state.pendingPolls.splice(idx, 1);
    broadcastAgentPollingIfChanged();
  });
}

function sessionFileMetadataFromPollReply(file) {
  if (!file || typeof file !== 'string') return { file };
  const normalized = file.split(path.sep).join('/');
  const base = { file: normalized };
  const metadataFile = normalized;
  if (!metadataFile.endsWith('/manifest.json') && metadataFile !== 'manifest.json') return base;
  if (!metadataFile.includes('.impeccable/live/previews/')
      && !metadataFile.includes('node_modules/.impeccable-live/')
      && !metadataFile.includes('src/lib/impeccable/')
      && !metadataFile.includes('/.impeccable-live/')) return base;

  let full;
  try {
    full = path.resolve(process.cwd(), metadataFile);
    const rel = path.relative(process.cwd(), full);
    if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) return base;
  } catch {
    return base;
  }

  try {
    const manifest = JSON.parse(readFileInside(process.cwd(), full, {
      encoding: 'utf8',
      maxBytes: MAX_LIVE_JSON_BYTES,
    }));
    if (manifest?.previewMode !== 'svelte-component'
        || !manifest.sourceFile) return base;
    return {
      file: String(manifest.sourceFile).split(path.sep).join('/'),
      sourceFile: String(manifest.sourceFile).split(path.sep).join('/'),
      previewFile: normalized,
      previewMode: manifest.previewMode,
    };
  } catch {
    return base;
  }
}

function inferSourceEventType(msg = {}, pendingEvents = state.pendingEvents) {
  const entriesForId = pendingEvents.filter((entry) => entry.event?.id === msg.id);
  const pendingTypes = new Set(entriesForId.map((entry) => entry.event?.type));
  if (msg.type === 'discarded' || msg.type === 'discard') return 'discard';
  if (msg.type === 'complete') {
    if (pendingTypes.has('carbonize_cleanup')) return 'carbonize_cleanup';
    return pendingTypes.has('accept') ? 'accept' : (pendingTypes.has('generate') ? 'generate' : undefined);
  }
  if (msg.type === 'steer_done') return 'steer';
  // `agent_done` can be the automatic acknowledgement for a carbonize Accept.
  // New pollers send sourceEventType explicitly; default to generate only for
  // older callers so a late worker cannot acknowledge a queued Accept.
  if (msg.type === 'agent_done' || msg.type === 'done') {
    // A `done` reply to a mount failure is the republish that unblocks the
    // browser. Without this the ack would look for a `generate` that was
    // already retired, the mount-failure event would stay queued, and the next
    // poll would hand the same failure back to the agent forever.
    if (!pendingTypes.has('generate') && pendingTypes.has('variant_mount_failed')) return 'variant_mount_failed';
    return 'generate';
  }
  // `error` is reference/live.md's documented failure reply, and parseReplyArgs
  // never sets sourceEventType on it (the poller is a fresh process that cannot
  // know what it leased). Returning undefined here makes acknowledgePendingEvent
  // match *any* event for this id: a stale generate worker's failure silently
  // consumed the user's queued Accept, which was then never delivered to any
  // agent and left the browser in SAVING forever. Attribute the failure to the
  // event this agent actually holds a lease on, and otherwise to `generate` —
  // never to a wildcard. If that generate was already retired by an Accept, the
  // ack simply finds no match, which is the correct outcome for a stale reply.
  if (msg.type === 'error') {
    return entriesForId.find(isLeased)?.event?.type || 'generate';
  }
  return undefined;
}

function handlePollPost(req, res) {
  if (!requireLivePostAuth(req, res)) return;
  readBoundedJson(req, { maxBytes: MAX_LIVE_JSON_BYTES }).then((msg) => {
    const pendingApplyDeferred = manualApply.getDeferred(msg.id);
    if (pendingApplyDeferred) {
      const validation = manualApply.validateResultMessage(msg, pendingApplyDeferred);
      if (!validation.ok) {
        recordManualEditActivity('manual_edit_apply_reply_invalid', {
          id: msg.id,
          pageUrl: pendingApplyDeferred.pageUrl,
          chunk: pendingApplyDeferred.event?.chunk || null,
          repair: pendingApplyDeferred.event?.repair || null,
          reason: validation.body?.reason || validation.body?.error || 'invalid_manual_apply_result',
          status: msg.data?.status || null,
        });
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(validation.body));
        return;
      }
      recordManualEditActivity('manual_edit_apply_reply_received', {
        id: msg.id,
        pageUrl: pendingApplyDeferred.pageUrl,
        chunk: pendingApplyDeferred.event?.chunk || null,
        repair: pendingApplyDeferred.event?.repair || null,
        status: validation.result.status,
        appliedCount: validation.result.appliedEntryIds.length,
        failed: summarizeManualApplyFailures(validation.result.failed),
        fileCount: validation.result.files.length,
        noteCount: validation.result.notes.length,
      });
      manualApply.resolveDeferred(msg.id, validation.result);
      acknowledgePendingEvent(msg.id);
      flushPendingPolls();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    if (manualApply.hasTimedOutId(msg.id)) {
      const rollback = manualApply.rollbackTimedOutReply(msg);
      recordManualEditActivity('manual_edit_apply_stale_reply_rejected', {
        id: msg.id,
        rolledBackFileCount: rollback.rolledBackFiles?.length || 0,
        rollbackFailureCount: rollback.rollbackFailures?.length || 0,
      });
      res.writeHead(409, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'stale_manual_edit_apply_reply', ...rollback }));
      return;
    }
    const sourceEventType = msg.sourceEventType || inferSourceEventType(msg);
    if (msg.type === 'retry') {
      const releasedEvent = releasePendingEvent(msg.id, sourceEventType);
      if (!releasedEvent) {
        res.writeHead(msg.id ? 404 : 400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: msg.id ? 'unknown_poll_retry_id' : 'missing_poll_retry_id',
          id: msg.id,
        }));
        return;
      }
      flushPendingPolls();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, released: true }));
      return;
    }
    const pendingEventBeforeAck = findPendingEventById(msg.id, sourceEventType);
    if (pendingEventBeforeAck?.type === 'steer' && msg.type === 'steer_done'
        && !msg.file && !(typeof msg.message === 'string' && msg.message.trim())) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: 'steer_done_requires_file_or_message',
        hint: 'Reply with --file after writing source, or include a message explaining an intentional no-op.',
      }));
      return;
    }
    const acknowledgedEvent = acknowledgePendingEvent(msg.id, sourceEventType);
    let skipJournalReply = false;
    let existingSession = null;
    if (!acknowledgedEvent && state.sessionStore && msg.id) {
      try {
        existingSession = state.sessionStore.getSnapshot(msg.id, { includeCompleted: true });
        if (!existingSession?.updatedAt) existingSession = null;
        skipJournalReply = existingSession?.phase === 'completed' || existingSession?.phase === 'discarded';
      } catch { /* fall through and record the reply normally */ }
    }
    if (!acknowledgedEvent && !existingSession) {
      recordManualEditActivity('manual_edit_poll_reply_unknown', {
        id: msg.id || null,
        type: msg.type || null,
      });
      res.writeHead(msg.id ? 404 : 400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: msg.id ? 'unknown_poll_reply_id' : 'missing_poll_reply_id',
        id: msg.id,
      }));
      return;
    }
    const replyFileMeta = sessionFileMetadataFromPollReply(msg.file);
    // A publish (done reply carrying a component manifest) snapshots the
    // variant files into a fresh revision dir before the browser is told:
    // the import path changes every publish, so no transform cache can pin a
    // stale compile of a republished module (node_modules is unwatched).
    // Broken variants are bounced HERE, before the browser imports anything:
    // a compile error that reaches the page is a red overlay in the user's
    // face; bounced at publish it is a private fix with file and line.
    if (replyFileMeta.previewMode === 'svelte-component'
        && msg.id
        && (msg.type === 'done' || !msg.type)) {
      let compileCheck = { ok: true, failures: [] };
      try { compileCheck = compileCheckVariants(msg.id, process.cwd()); } catch { /* best-effort */ }
      if (!compileCheck.ok) {
        res.writeHead(422, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: 'variant_compile_failed',
          id: msg.id,
          failures: compileCheck.failures,
          _instructions: 'The publish was NOT delivered: the listed variant file(s) do not compile, so the browser never saw them. Fix each failure at the given file and line (the most common cause is a second top-level <style> element; Svelte allows exactly one, so merge all rules into the existing block), then send the same --reply done again.',
        }));
        return;
      }
      try { bumpSvelteComponentPreviewRevision(msg.id, process.cwd()); } catch { /* best-effort */ }
    }
    if (state.sessionStore && msg.id && !skipJournalReply) {
      try {
        const eventType = msg.type === 'steer_done'
          ? 'steer_done'
          : msg.type === 'discard' || msg.type === 'discarded'
            ? 'discarded'
            : msg.type === 'complete'
              ? 'complete'
              : msg.type === 'error'
                ? 'agent_error'
                : 'agent_done';
        state.sessionStore.appendEvent({
          type: eventType,
          id: msg.id,
          file: replyFileMeta.file,
          sourceFile: replyFileMeta.sourceFile,
          previewFile: replyFileMeta.previewFile,
          previewMode: replyFileMeta.previewMode,
          message: msg.message,
          sourceEventType: acknowledgedEvent?.type,
          carbonize: msg.data?.carbonize === true,
        });
      } catch { /* keep reply path best-effort; browser still needs SSE */ }
    }
    flushPendingPolls();
    // The agent's free-form message/data can contain unrendered source or
    // compiler errors. Only a narrow browser-safe projection reaches SSE.
    broadcast(pageSafeAgentReply(msg, pageSafeFileMetadata(replyFileMeta)));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
  }).catch((error) => sendHttpInputError(req, res, error));
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

let httpServer = null;

function shutdown() {
  cleanupSvelteComponentSessionsBeforeExit();
  removeLiveServerInfo(process.cwd());
  if (state.leaseTimer) clearTimeout(state.leaseTimer);
  state.leaseTimer = null;
  if (state.sessionDir) {
    try { fs.rmSync(state.sessionDir, { recursive: true, force: true }); } catch {}
  }
  for (const res of state.sseClients) { try { res.end(); } catch {} }
  state.sseClients.clear();
  for (const poll of state.pendingPolls) poll.resolve({ type: 'exit' });
  state.pendingPolls.length = 0;
  if (httpServer) httpServer.close();
  process.exit(0);
}

function cleanupSvelteComponentSessionsBeforeExit() {
  try {
    removeAllSvelteComponentSessions(process.cwd());
  } catch (err) {
    console.warn('[impeccable] Svelte component session cleanup failed:', err.message);
  }
}

/**
 * Old detached component sessions contain source-derived manifests and stubs
 * that the inspected page's dev server can read directly. Preserve their
 * generated work outside the dev-served project, but invalidate those active
 * sessions rather than continuing to expose route source.
 */
function quarantineLegacySvelteSessionsOnStartup() {
  const privateRoot = getLivePrivateDir(process.cwd());
  const moved = quarantineLegacySvelteComponentSessions(process.cwd(), privateRoot);
  for (const { source, destination, id } of moved) {
    console.warn(`[impeccable] retired legacy Svelte ${id}; restart its preview or review the deferred decision. Generated work preserved: ${source} -> ${destination}`);
  }
  return moved;
}

// Accept receipts are a short-lived idempotency record for a single accept.
// Nothing reads one after the session that wrote it is gone, so they only need
// to outlive a crash-and-retry window.
const ACCEPT_RECEIPT_MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000;

function sweepStaleAcceptReceiptsOnStartup() {
  try {
    const dir = path.join(getLivePrivateDir(process.cwd()), 'accept-receipts');
    if (!fs.existsSync(dir)) return;
    const cutoff = Date.now() - ACCEPT_RECEIPT_MAX_AGE_MS;
    let removed = 0;
    for (const name of fs.readdirSync(dir)) {
      if (!name.endsWith('.json') && !name.endsWith('.tmp')) continue;
      const file = path.join(dir, name);
      try {
        if (fs.statSync(file).mtimeMs >= cutoff) continue;
        fs.rmSync(file, { force: true });
        removed++;
      } catch { /* non-fatal */ }
    }
    if (removed > 0) console.log(`[impeccable] removed ${removed} accept receipt(s) older than 14 days`);
  } catch (err) {
    console.warn('[impeccable] accept receipt retention sweep failed:', err.message);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);

if (args.includes('--help') || args.includes('-h')) {
  console.log(`Usage: node live-server.mjs [options]

Start the live variant mode server (zero dependencies).

Commands:
  (default)     Start the server (foreground)
  stop          Stop the server and remove the injected live.js script tag
  stop --keep-inject   Stop the server only (leave the script tag in the HTML entry)

Options:
  --background  Start detached, print connection JSON to stdout, then exit
  --port=PORT   Use a specific port (default: auto-detect starting at 8400)
  --keep-inject Only with stop: skip live-inject.mjs --remove
  --help        Show this help

Endpoints:
  /live.js             Browser script (element picker + variant cycling)
  /detect.js           Detection overlay (backwards compatible)
  /modern-screenshot.js Vendored modern-screenshot UMD build (lazy-loaded by live.js)
  /annotation          POST raw image/png to stage a variant screenshot
  /events              SSE stream (server→browser) + POST (browser→server)
  /poll                Long-poll for agent CLI
  /manual-edit-stash   Stage browser copy edits
  /manual-edit-commit  Apply staged browser copy edits
  /manual-edit-discard Discard staged browser copy edits
  /source              Controller-only inert source reader
  /status              Durable recovery status (token-protected)
  /health              Health check`);
  process.exit(0);
}

if (args.includes('stop')) {
  const keepInject = args.includes('--keep-inject');
  try {
    const { info } = readLiveServerInfo(process.cwd()) || {};
    const res = await fetch(`${liveHelperBase(info.port)}/stop`, {
      method: 'POST',
      headers: { 'X-Impeccable-Token': info.token },
    });
    if (res.ok) console.log(`Stopped live server on port ${info.port}.`);
  } catch {
    console.log('No running live server found.');
  }
  if (!keepInject) {
    const injectPath = path.join(__dirname, 'live-inject.mjs');
    try {
      const out = execFileSync(process.execPath, [injectPath, '--remove'], {
        encoding: 'utf-8',
        cwd: process.cwd(),
      });
      const line = out.trim().split('\n').filter(Boolean).pop();
      if (line) {
        try {
          const j = JSON.parse(line);
          if (j.removed === true) {
            console.log(`Removed live script tag from ${j.file}.`);
          }
        } catch {
          /* ignore non-JSON lines */
        }
      }
    } catch (err) {
      const detail = err.stderr?.toString?.().trim?.()
        || err.stdout?.toString?.().trim?.()
        || err.message
        || String(err);
      console.warn(`Note: could not remove live script tag (${detail.split('\n')[0]})`);
    }
  }
  process.exit(0);
}

// --background: spawn a detached child server, wait for it to be ready,
// print the connection JSON, then exit.  This keeps the startup command
// simple (no shell backgrounding or chained commands).
if (args.includes('--background')) {
  // Do the fail-closed migration in the visible parent before spawning a
  // detached child with ignored stdio. If ownership/path checks fail, the
  // caller sees the exact error immediately instead of a generic 10s timeout.
  const existing = readLiveServerInfo(process.cwd())?.info;
  if (existing?.pid && isLiveServerPidReachable(existing.pid)) {
    console.error(`Live server already running on port ${existing.port} (pid ${existing.pid}).`);
    process.exit(1);
  }
  try {
    const moved = migrateLegacyLivePrivateArtifacts(process.cwd());
    quarantineLegacySvelteSessionsOnStartup();
    readManualEditsBufferStrict(process.cwd());
    if (livePrivateDirIsVolatile(process.cwd())) {
      console.warn('[impeccable] private Live state uses OS temporary storage because the app root contains the user data directory; recovery after reboot or temp cleanup is not guaranteed.');
    }
    for (const { source, destination } of moved) {
      console.warn(`[impeccable] private Live state migration: ${source} -> ${destination}`);
    }
  } catch (error) {
    console.error(`[impeccable] live startup stopped: ${error.message}`);
    process.exit(1);
  }
  if (manualApply.readTransaction()) {
    console.warn('[impeccable] an interrupted copy-edit transaction needs review in the trusted controller; no automatic rollback was performed.');
  }
  const childArgs = args.filter(a => a !== '--background');
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url), ...childArgs], {
    detached: true,
    stdio: 'ignore',
    cwd: process.cwd(),
  });
  child.unref();

  // Poll for the PID file (the child writes it once the HTTP server is listening).
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      const { info } = readLiveServerInfo(process.cwd()) || {};
      if (info.pid !== process.pid) {
        // Output JSON so the agent can read port + token from stdout.
        console.log(JSON.stringify(info));
        process.exit(0);
      }
    } catch { /* not ready yet */ }
    // The detached child is typically listening in 35-45ms. A 200ms polling
    // floor dominated configured cold Live startup; poll cheaply and return
    // as soon as the child has written its ready record.
    await new Promise(r => setTimeout(r, 5));
  }
  console.error('Timed out waiting for live server to start.');
  process.exit(1);
}

// Check for existing session
const existingRecord = readLiveServerInfo(process.cwd());
if (existingRecord?.info) {
  const existing = existingRecord.info;
  try {
    process.kill(existing.pid, 0);
    console.error(`Live server already running on port ${existing.port} (pid ${existing.pid}).`);
    console.error('Stop it first with: node ' + path.basename(fileURLToPath(import.meta.url)) + ' stop');
    process.exit(1);
  } catch {
    try { fs.unlinkSync(existingRecord.path); } catch {}
  }
}

state.token = randomUUID();
state.pageToken = randomUUID();
const migrated = migrateLegacyLivePrivateArtifacts(process.cwd());
if (livePrivateDirIsVolatile(process.cwd())) {
  console.warn('[impeccable] private Live state uses OS temporary storage; recovery after reboot or temp cleanup is not guaranteed.');
}
for (const { source, destination } of migrated) {
  console.warn(`[impeccable] private Live state migration: ${source} -> ${destination}`);
}
state.sessionStore = createLiveSessionStore({ cwd: process.cwd() });
state.pendingDispatchAuth = createPendingDispatchAuth(process.cwd());
readManualEditsBufferStrict(process.cwd());
quarantineLegacySvelteSessionsOnStartup();
if (manualApply.readTransaction()) {
  console.warn('[impeccable] interrupted copy-edit transaction preserved for trusted-controller review; no source rollback was performed.');
}
sweepStaleAcceptReceiptsOnStartup();
restorePendingEventsFromStore();
manualApply.pruneStaleEvidence();
const portArg = args.find(a => a.startsWith('--port='));
state.port = portArg ? parseInt(portArg.split('=')[1], 10) : await findOpenPort();
// Annotation screenshots are page-originated, never source journals. Session
// them by token so concurrent projects (or quick restarts) do not collide.
const annotRoot = getLiveAnnotationsDir(process.cwd());
fs.mkdirSync(annotRoot, { recursive: true });
state.sessionDir = fs.mkdtempSync(path.join(annotRoot, 'session-'));

const { detectScript, liveScriptParts } = loadBrowserScripts();
httpServer = applyDefensiveServerTimeouts(http.createServer(createRequestHandler({ detectScript, liveScriptParts })));

httpServer.listen(state.port, LIVE_HELPER_HOST, () => {
  writeLiveServerInfo(process.cwd(), {
    pid: process.pid,
    port: state.port,
    token: state.token,
    pageToken: state.pageToken,
  });
  console.log(`\nImpeccable live server running on ${liveHelperBase(state.port)}`);
  console.log(`Controller: ${liveControllerUrl(state.port, state.token)}\n`);
  console.log(`Script: ${liveHelperBase(state.port)}/live.js`);
  console.log('Inject: managed by live-inject.mjs; Astro source tags use is:inline automatically.');
  console.log(`Stop:   node ${path.basename(fileURLToPath(import.meta.url))} stop`);
});

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
