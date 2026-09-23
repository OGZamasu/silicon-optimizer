/**
 * A separate-origin controller surface. This document never receives the
 * inspected page's DOM or script; all untrusted event details are text only.
 * The controller credential arrives in a URL fragment (not an HTTP request)
 * from the CLI and remains in this origin's sessionStorage for reloads.
 */
export function renderControlUi(nonce) {
  return `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Impeccable Live Controller</title>
<style>
  :root{font:14px system-ui,-apple-system,sans-serif;color-scheme:dark;background:#171717;color:#f5f5f5}
  body{max-width:980px;margin:2rem auto;padding:0 1rem}h1{font-size:1.5rem}h2{margin-top:2rem;font-size:1.1rem}
  p{line-height:1.5;color:#d0d0d0}button,input{font:inherit}button{border:1px solid #777;border-radius:6px;background:#303030;color:#fff;padding:.5rem .8rem;cursor:pointer;margin:.25rem}
  button:hover{background:#414141}button:focus-visible,input:focus-visible{outline:2px solid #e6b933}
  input{background:#242424;border:1px solid #777;border-radius:6px;color:#fff;padding:.5rem;width:min(36rem,90%)}
  article{border:1px solid #555;border-radius:8px;padding:1rem;margin:.6rem 0;background:#222}pre{white-space:pre-wrap;overflow-wrap:anywhere;max-height:24rem;overflow:auto}
  .error{color:#ff9999}.muted{color:#aaa}.row{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center}label{display:block;margin:.5rem 0}
</style>
<h1>Impeccable Live Controller</h1>
<p>This is the trusted control window. The inspected page can propose source-changing actions, but only a confirmation here can dispatch them. Keep this window separate from the page you are inspecting.</p>
<p id="connection" role="status">Connecting…</p>
<section><h2>Actions awaiting confirmation</h2><div id="approvals"></div></section>
<section><h2>Staged copy edits</h2><p id="edits-status" class="muted"></p><div id="edits"></div></section>
<section><h2>Source and design</h2><label>Project-relative source path <input id="source-path" autocomplete="off" spellcheck="false"></label><button id="read-source">Read source</button><button id="read-design">Read DESIGN.md</button><button id="read-design-json">Read design system JSON</button><pre id="source-output"></pre></section>
<section><h2>End live mode</h2><p>Closing the inspected page does not stop the helper or agent. Stop it here when you are done.</p><button id="stop-live">Stop live server and agent</button></section>
<script nonce="${nonce}">
(() => {
  'use strict';
  window.opener = null;
  const fragment = new URLSearchParams(location.hash.slice(1));
  const tokenFromLink = fragment.get('token');
  let token = tokenFromLink;
  if (tokenFromLink) {
    try { sessionStorage.setItem('impeccable-controller-token', tokenFromLink); } catch { /* in-memory for this tab */ }
    // Strip the bearer fragment even when tab storage is unavailable.
    try { history.replaceState(null, '', location.pathname + location.search); }
    catch { try { location.hash = ''; } catch {} }
  }
  if (!token) {
    try { token = sessionStorage.getItem('impeccable-controller-token'); } catch { /* reopen CLI URL */ }
  }
  const connection = document.getElementById('connection');
  const approvals = document.getElementById('approvals');
  const edits = document.getElementById('edits');
  const editsStatus = document.getElementById('edits-status');
  const sourceOutput = document.getElementById('source-output');
  const approvalCards = new Map();
  const draftCards = new Map();
  if (!token) {
    connection.className = 'error';
    connection.textContent = 'No controller credential. Open the controller URL printed by impeccable live.';
    return;
  }
  const auth = { 'X-Impeccable-Token': token };
  async function json(path, options = {}) {
    const res = await fetch(path, { cache: 'no-store', ...options, headers: { ...auth, ...(options.headers || {}) } });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || 'HTTP ' + res.status);
    return body;
  }
  function text(tag, value, className) {
    const el = document.createElement(tag);
    el.textContent = String(value ?? '');
    if (className) el.className = className;
    return el;
  }
  function button(label, action) {
    const el = text('button', label);
    el.type = 'button';
    el.addEventListener('click', async () => {
      el.disabled = true;
      try { await action(); await refresh(); }
      catch (error) { connection.className = 'error'; connection.textContent = error.message; }
      finally { el.disabled = false; }
    });
    return el;
  }
  function syncCards(container, items, cache, emptyMessage, render) {
    if (!items.length) {
      cache.clear();
      container.replaceChildren(text('p', emptyMessage, 'muted'));
      return;
    }
    if (container.firstElementChild?.tagName === 'P') container.replaceChildren();
    const seen = new Set();
    for (const item of items) {
      seen.add(item.key);
      const old = cache.get(item.key);
      if (old?.revision === item.revision) continue;
      const card = render(item.value);
      if (old) old.node.replaceWith(card);
      else container.append(card);
      cache.set(item.key, { revision: item.revision, node: card });
    }
    for (const [key, old] of cache) {
      if (seen.has(key)) continue;
      old.node.remove();
      cache.delete(key);
    }
  }
  async function refresh() {
    const [pending, drafts, status] = await Promise.all([
      json('/control/approvals'),
      json('/manual-edit-stash?token=' + encodeURIComponent(token)),
      json('/status?token=' + encodeURIComponent(token)),
    ]);
    connection.className = '';
    connection.textContent = 'Connected · agent ' + (status.agentPolling ? 'polling' : 'not polling') + ' · ' + (status.activeSessions?.length || 0) + ' active session(s)';
    syncCards(approvals, pending.approvals.map((item) => ({
      key: item.id, revision: JSON.stringify(item.msg), value: item,
    })), approvalCards, 'No actions are waiting.', (item) => {
      const card = document.createElement('article');
      const label = typeof item.msg.pageUrl === 'string' ? item.msg.pageUrl
        : typeof item.msg.id === 'string' ? item.msg.id : 'page';
      card.append(text('strong', item.msg.type + ' · ' + label.slice(0, 200)));
      const detail = text('pre', JSON.stringify(item.msg, null, 2));
      card.append(detail);
      if (item.msg.type === 'generate' && typeof item.msg.screenshotPath === 'string') {
        card.append(button('View annotation', async () => {
          const res = await fetch('/control/annotation/' + encodeURIComponent(item.msg.id), { headers: auth, cache: 'no-store' });
          if (!res.ok) throw new Error('Annotation read failed: HTTP ' + res.status);
          const blob = new Blob([await res.arrayBuffer()], { type: 'image/png' });
          const url = URL.createObjectURL(blob);
          const img = document.createElement('img');
          img.alt = 'Page-submitted annotation for this action';
          img.style.cssText = 'display:block;max-width:100%;max-height:32rem;margin:.5rem 0';
          img.onload = img.onerror = () => URL.revokeObjectURL(url);
          img.src = url;
          card.insertBefore(img, detail.nextSibling);
        }));
      }
      card.append(button('Approve this action', () => json('/control/approvals/' + encodeURIComponent(item.id) + '/approve', { method: 'POST' })));
      card.append(button('Reject', () => json('/control/approvals/' + encodeURIComponent(item.id) + '/reject', { method: 'POST' })));
      return card;
    });
    editsStatus.textContent = drafts.commitInProgress
      ? 'Copy-edit apply is running. Review controls will return when it finishes.' : '';
    const pages = new Set((drafts.entries || []).map((entry) => entry.pageUrl).filter(Boolean));
    const repairPage = drafts.repair ? (drafts.repair.pageUrl ?? '') : null;
    if (repairPage !== null) pages.add(repairPage);
    syncCards(edits, [...pages].map((pageUrl) => ({
      key: pageUrl,
      revision: [drafts.pageDigests[pageUrl], drafts.commitInProgress,
        JSON.stringify(repairPage === pageUrl ? drafts.repair : null)].join(':'),
      value: pageUrl,
    })), draftCards, 'No staged copy edits.', (pageUrl) => {
      const entries = drafts.entries.filter((entry) => entry.pageUrl === pageUrl);
      const card = document.createElement('article');
      card.append(text('strong', (pageUrl || 'Unknown route') + ' · ' + entries.length + ' staged edit(s)'));
      card.append(text('pre', JSON.stringify(entries, null, 2)));
      const repair = repairPage === pageUrl ? drafts.repair : null;
      if (repair) {
        card.append(text('p', 'Interrupted Apply: review the current source before deciding. Rollback replaces the listed current files with their pre-Apply snapshots; it can overwrite later edits.', 'error'));
        card.append(text('pre', JSON.stringify(repair, null, 2)));
      }
      const page = encodeURIComponent(pageUrl);
      const apply = button('Apply to source', () => json('/manual-edit-commit?pageUrl=' + page + '&async=1', {
        method: 'POST', headers: { 'X-Impeccable-Review-Digest': drafts.pageDigests[pageUrl] },
      }));
      apply.disabled = drafts.commitInProgress || Boolean(drafts.repair);
      card.append(apply);
      const discard = button('Discard drafts', () => json('/manual-edit-discard?pageUrl=' + page, {
        method: 'POST', headers: { 'X-Impeccable-Review-Digest': drafts.pageDigests[pageUrl] },
      }));
      discard.disabled = drafts.commitInProgress || Boolean(drafts.repair);
      card.append(discard);
      if (repair) {
        if (repair.retryAvailable) {
          const retry = button('Retry repair', () => json('/manual-edit-commit?pageUrl=' + page + '&async=1&repair=1&transactionId=' + encodeURIComponent(repair.id), { method: 'POST' }));
          retry.disabled = drafts.commitInProgress;
          card.append(retry);
        }
        const rollback = button('Rollback to saved snapshots', () => {
          if (!window.confirm('This will replace the listed current files with their pre-Apply contents. Review any later edits before continuing. Roll back?')) return;
          return json('/manual-edit-repair-decision?pageUrl=' + page, {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pageUrl, action: 'rollback', transactionId: repair.id }),
          });
        });
        rollback.disabled = drafts.commitInProgress;
        card.append(rollback);
      }
      return card;
    });
  }
  document.getElementById('read-source').addEventListener('click', async () => {
    const path = document.getElementById('source-path').value.trim();
    if (!path) return;
    const res = await fetch('/source?token=' + encodeURIComponent(token) + '&path=' + encodeURIComponent(path), { cache: 'no-store' });
    sourceOutput.textContent = res.ok ? await res.text() : 'Source read failed: HTTP ' + res.status;
  });
  document.getElementById('read-design').addEventListener('click', async () => {
    const res = await fetch('/design-system/raw?token=' + encodeURIComponent(token), { cache: 'no-store' });
    sourceOutput.textContent = res.ok ? await res.text() : 'Design read failed: HTTP ' + res.status;
  });
  document.getElementById('read-design-json').addEventListener('click', async () => {
    const res = await fetch('/design-system.json?token=' + encodeURIComponent(token), { cache: 'no-store' });
    sourceOutput.textContent = res.ok ? JSON.stringify(await res.json(), null, 2) : 'Design read failed: HTTP ' + res.status;
  });
  document.getElementById('stop-live').addEventListener('click', async () => {
    if (!window.confirm('Stop Impeccable Live and its agent now?')) return;
    try {
      const res = await fetch('/stop', { method: 'POST', headers: auth });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      clearInterval(refreshTimer);
      connection.className = '';
      connection.textContent = 'Live server stopped.';
    } catch (error) {
      connection.className = 'error';
      connection.textContent = 'Stop failed: ' + error.message;
    }
  });
  refresh().catch((error) => { connection.className = 'error'; connection.textContent = error.message; });
  const refreshTimer = setInterval(() => refresh().catch((error) => { connection.className = 'error'; connection.textContent = error.message; }), 3000);
})();
</script></html>`;
}
