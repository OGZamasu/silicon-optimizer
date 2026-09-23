import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import os from 'node:os';
import { resolveProjectRoot } from '../context.mjs';
import { designSidecarCandidatesFor } from './staleness.mjs';
export { IMPECCABLE_COMMAND_PREFIX } from './provider.mjs';

export const IMPECCABLE_DIR = '.impeccable';
export const LIVE_DIR = 'live';
export const CRITIQUE_DIR = 'critique';

export function getImpeccableDir(cwd = process.cwd(), options = {}) {
  return path.join(resolveProjectRoot(cwd, options), IMPECCABLE_DIR);
}

export function getDesignSidecarPath(cwd = process.cwd(), options = {}) {
  return path.join(getImpeccableDir(cwd, options), 'design.json');
}

export function getDesignSidecarCandidates(cwd = process.cwd(), contextDir = cwd, options = {}) {
  return designSidecarCandidatesFor(resolveProjectRoot(cwd, options), contextDir);
}

export function resolveDesignSidecarPath(cwd = process.cwd(), contextDir = cwd, options = {}) {
  return firstExisting(getDesignSidecarCandidates(cwd, contextDir, options));
}

export function getLiveDir(cwd = process.cwd(), options = {}) {
  return path.join(getImpeccableDir(cwd, options), LIVE_DIR);
}

export function getLiveConfigPath(cwd = process.cwd(), options = {}) {
  return path.join(getLiveDir(cwd, options), 'config.json');
}

export function getLegacyLiveConfigPath(scriptsDir) {
  return path.join(scriptsDir, 'config.json');
}

export function resolveLiveConfigPath({ cwd = process.cwd(), scriptsDir, env = process.env, targetPath } = {}) {
  if (env.IMPECCABLE_LIVE_CONFIG && env.IMPECCABLE_LIVE_CONFIG.trim()) {
    const configured = env.IMPECCABLE_LIVE_CONFIG.trim();
    return path.isAbsolute(configured) ? configured : path.resolve(cwd, configured);
  }
  const primary = getLiveConfigPath(cwd, { targetPath });
  if (fs.existsSync(primary)) return primary;
  if (scriptsDir) {
    const legacy = getLegacyLiveConfigPath(scriptsDir);
    if (fs.existsSync(legacy)) return legacy;
  }
  return primary;
}

export function getLiveServerPath(cwd = process.cwd(), options = {}) {
  return path.join(getLiveDir(cwd, options), 'server.json');
}

export function getLiveControllerPath(cwd = process.cwd(), options = {}) {
  const root = fs.realpathSync(path.resolve(resolveProjectRoot(cwd, options)));
  const digest = createHash('sha256').update(root).digest('hex');
  const uid = typeof process.getuid === 'function' ? process.getuid() : 'user';
  // A project itself can live at the OS temp root. Never choose a credential
  // directory that the inspected project's dev server could serve. Judge the
  // directory the file lands in, not its parent: a project named exactly
  // `impeccable-live-<uid>` under a candidate would otherwise hold its own
  // controller credential.
  const directory = [os.tmpdir(), os.homedir()]
    .map((candidate) => { try { return fs.realpathSync(candidate); } catch { return null; } })
    .map((candidate) => candidate && path.join(candidate, `impeccable-live-${uid}`))
    .find((candidate) => {
      if (!candidate) return false;
      const relative = path.relative(root, candidate);
      return relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative);
    });
  if (!directory) throw new Error('No private credential directory outside the project root');
  return path.join(directory, `${digest}.controller.json`);
}

function ensurePrivateControllerDirectory(filePath) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()
      || (typeof process.getuid === 'function' && stat.uid !== process.getuid())
      || (stat.mode & 0o077) !== 0) {
    throw new Error('Impeccable controller directory is not private');
  }
}

function assertPrivateDirectory(dir) {
  const stat = fs.lstatSync(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()
      || (typeof process.getuid === 'function' && stat.uid !== process.getuid())
      || (stat.mode & 0o077) !== 0) {
    throw new Error(`Impeccable private data directory is not owner-only: ${dir}`);
  }
}

function livePrivateLocation(cwd, options = {}) {
  const root = fs.realpathSync(path.resolve(resolveProjectRoot(cwd, options)));
  const home = fs.realpathSync(os.homedir());
  const temp = fs.realpathSync(os.tmpdir());
  const candidates = [
    process.platform === 'darwin'
      ? { anchor: home, base: path.join(home, 'Library', 'Application Support', 'Impeccable Live'), volatile: false }
      : { anchor: home, base: path.join(home, '.local', 'state', 'impeccable-live'), volatile: false },
    { anchor: home, base: path.join(home, '.local', 'state', 'impeccable-live'), volatile: false },
    { anchor: temp, base: path.join(temp, `impeccable-live-state-${typeof process.getuid === 'function' ? process.getuid() : 'user'}`), volatile: true },
  ];
  const choice = candidates.find(({ base }) => {
    const relative = path.relative(root, base);
    return relative && (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative));
  });
  if (!choice) throw new Error(`No private Live data location outside app root ${root}`);
  const digest = createHash('sha256').update(root).digest('hex');
  return { ...choice, path: path.join(choice.base, digest) };
}

function privateLiveDataPath(cwd, options = {}) {
  return livePrivateLocation(cwd, options).path;
}

export function getLivePrivateDirPath(cwd = process.cwd(), options = {}) {
  return privateLiveDataPath(cwd, options);
}

export function livePrivateDirIsVolatile(cwd = process.cwd(), options = {}) {
  return livePrivateLocation(cwd, options).volatile;
}

function existsNoFollow(filePath) {
  try { fs.lstatSync(filePath); return true; }
  catch (error) { if (error?.code === 'ENOENT') return false; throw error; }
}

const migratedPrivateRoots = new Set();
const lockPause = new Int32Array(new SharedArrayBuffer(4));

function withMigrationLock(privateRoot, action) {
  const lock = path.join(privateRoot, '.migration.lock');
  const deadline = Date.now() + 10_000;
  let fd;
  while (fd === undefined) {
    try {
      fd = fs.openSync(lock, 'wx', 0o600);
      fs.writeSync(fd, JSON.stringify({ pid: process.pid, at: Date.now() }));
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
      let holder = null;
      try { holder = JSON.parse(fs.readFileSync(lock, 'utf8')); } catch {}
      if (Number.isSafeInteger(holder?.pid) && holder.pid > 0) {
        try { process.kill(holder.pid, 0); }
        catch (killError) {
          if (killError?.code === 'ESRCH') { try { fs.unlinkSync(lock); } catch {} continue; }
        }
      }
      if (Date.now() >= deadline) throw new Error(`Live state migration is locked at ${lock}; retry after the other process finishes`);
      Atomics.wait(lockPause, 0, 0, 20);
    }
  }
  try { return action(); }
  finally {
    fs.closeSync(fd);
    try { fs.unlinkSync(lock); } catch {}
  }
}

function assertLegacyPathComponents(root, target) {
  const relative = path.relative(root, target);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`Legacy Live path escapes app root: ${target}`);
  }
  let current = root;
  for (const part of relative.split(path.sep)) {
    current = path.join(current, part);
    let stat;
    try { stat = fs.lstatSync(current); }
    catch (error) { if (error?.code === 'ENOENT') return false; throw error; }
    if (stat.isSymbolicLink()) throw new Error(`Legacy Live path contains a symlink: ${current}`);
  }
  return true;
}

/**
 * Old Live state lived under the app root and may contain source bytes. The
 * dev server can serve that directory regardless of filesystem mode. Move
 * only named Live-owned records to a private, outside-app directory before a
 * new helper starts; never copy-and-leave exposed records or overwrite a
 * prior private record. A failed migration lists any already-moved paths.
 */
export function migrateLegacyLivePrivateArtifacts(cwd = process.cwd(), options = {}) {
  const root = fs.realpathSync(path.resolve(resolveProjectRoot(cwd, options)));
  const location = livePrivateLocation(root, options);
  const privateRoot = location.path;
  const relative = path.relative(location.anchor, privateRoot).split(path.sep);
  let current = location.anchor;
  for (const part of relative) {
    current = path.join(current, part);
    if (existsNoFollow(current)) {
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`Private Live location contains a symlink or non-directory: ${current}`);
    } else {
      fs.mkdirSync(current, { mode: 0o700 });
    }
  }
  fs.mkdirSync(privateRoot, { recursive: true, mode: 0o700 });
  assertPrivateDirectory(path.dirname(privateRoot));
  assertPrivateDirectory(privateRoot);
  const realPrivateRoot = fs.realpathSync(privateRoot);
  const realRelative = path.relative(root, realPrivateRoot);
  if (!realRelative || (realRelative !== '..' && !realRelative.startsWith(`..${path.sep}`) && !path.isAbsolute(realRelative))) {
    throw new Error(`Private Live data location is inside app root: ${realPrivateRoot}`);
  }
  if (migratedPrivateRoots.has(privateRoot)) return [];
  const moved = withMigrationLock(privateRoot, () => migrateLegacyLivePrivateArtifactsUnlocked(root, privateRoot));
  migratedPrivateRoots.add(privateRoot);
  return moved;
}

function migrateLegacyLivePrivateArtifactsUnlocked(root, privateRoot) {
  const moved = [];
  const specs = [
    { from: '.impeccable/live/sessions', to: 'sessions', kind: 'directory', allowed: /^[A-Za-z0-9_-]{1,128}(?:\.snapshot)?\.json(?:l)?$/, quarantineDuplicates: true },
    { from: '.impeccable-live/sessions', to: 'sessions', kind: 'directory', allowed: /^[A-Za-z0-9_-]{1,128}(?:\.snapshot)?\.json(?:l)?$/, quarantineDuplicates: true },
    { from: '.impeccable/live/pending-manual-edits.json', to: 'pending-manual-edits.json', kind: 'file', quarantineDuplicates: true },
    { from: '.impeccable/live/manual-edit-apply-transaction.json', to: 'manual-edit-apply-transaction.json', kind: 'file', quarantineDuplicates: true },
    { from: '.impeccable/live/manual-edit-apply-transaction.json.tmp', to: `quarantine/legacy-transaction-tmp-${randomUUID()}.json`, kind: 'file' },
    { from: '.impeccable/live/manual-edit-evidence', to: 'manual-edit-evidence', kind: 'directory', allowed: /^[A-Za-z0-9_-]{1,128}\.json$/, quarantineDuplicates: true },
    { from: '.impeccable/live/manual-edit-events.jsonl', to: 'manual-edit-events.jsonl', kind: 'file', quarantineDuplicates: true },
    { from: '.impeccable/live/accept-receipts', to: 'accept-receipts', kind: 'directory', allowed: /^[A-Za-z0-9_-]{1,128}\.json(?:\.\d+\.\d+\.tmp)?$/, quarantineDuplicates: true },
    { from: '.impeccable/live/artifacts', to: `quarantine/legacy-artifacts-${randomUUID()}`, kind: 'quarantine' },
    { from: '.impeccable/live/cache', to: `quarantine/legacy-cache-${randomUUID()}`, kind: 'quarantine' },
  ];
  try {
    for (const spec of specs) {
      const source = path.join(root, ...spec.from.split('/'));
      if (!assertLegacyPathComponents(root, source)) continue;
      const sourceStat = fs.lstatSync(source);
      if (spec.kind === 'file' && !sourceStat.isFile()) throw new Error(`Legacy Live record is not a regular file: ${source}`);
      if (spec.kind !== 'file' && !sourceStat.isDirectory()) throw new Error(`Legacy Live record is not a directory: ${source}`);
      const destination = path.join(privateRoot, ...spec.to.split('/'));
      if (spec.kind === 'quarantine') {
        fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
        assertPrivateDirectory(path.dirname(destination));
        fs.renameSync(source, destination);
        fs.chmodSync(destination, 0o700);
        moved.push({ source, destination });
        continue;
      }
      if (spec.kind === 'file') {
        fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
        assertPrivateDirectory(path.dirname(destination));
        let target = destination;
        if (existsNoFollow(destination)) {
          if (!spec.quarantineDuplicates) throw new Error(`Private Live record already exists; refusing overwrite: ${source} -> ${destination}`);
          const quarantine = path.join(privateRoot, 'quarantine');
          fs.mkdirSync(quarantine, { recursive: true, mode: 0o700 });
          assertPrivateDirectory(quarantine);
          target = path.join(quarantine, `legacy-record-duplicate-${randomUUID()}-${path.basename(source)}`);
        }
        fs.renameSync(source, target);
        fs.chmodSync(target, 0o600);
        moved.push({ source, destination: target });
        continue;
      }
      fs.mkdirSync(destination, { recursive: true, mode: 0o700 });
      assertPrivateDirectory(destination);
      for (const name of fs.readdirSync(source)) {
        const fromFile = path.join(source, name);
        const toFile = path.join(destination, name);
        const sourceEntry = fs.lstatSync(fromFile);
        if (!spec.allowed.test(name) || !sourceEntry.isFile()) {
          // The exact generated parent is in scope, but unknown crash files
          // must not block migration and leave neighboring source journals
          // dev-served. Move each entry without following its contents or
          // symlink target, preserving it for explicit manual inspection.
          const quarantine = path.join(privateRoot, 'quarantine');
          fs.mkdirSync(quarantine, { recursive: true, mode: 0o700 });
          assertPrivateDirectory(quarantine);
          const unknownPath = path.join(quarantine, `legacy-unknown-${randomUUID()}`);
          fs.renameSync(fromFile, unknownPath);
          if (sourceEntry.isFile()) fs.chmodSync(unknownPath, 0o600);
          else if (sourceEntry.isDirectory()) fs.chmodSync(unknownPath, 0o700);
          moved.push({ source: fromFile, destination: unknownPath });
          continue;
        }
        if (existsNoFollow(toFile)) {
          if (!spec.quarantineDuplicates) throw new Error(`Private Live record already exists; refusing overwrite: ${fromFile} -> ${toFile}`);
          const quarantine = path.join(privateRoot, 'quarantine');
          fs.mkdirSync(quarantine, { recursive: true, mode: 0o700 });
          assertPrivateDirectory(quarantine);
          const duplicatePath = path.join(quarantine, `legacy-session-duplicate-${randomUUID()}-${name}`);
          fs.renameSync(fromFile, duplicatePath);
          fs.chmodSync(duplicatePath, 0o600);
          moved.push({ source: fromFile, destination: duplicatePath });
          continue;
        }
        fs.renameSync(fromFile, toFile);
        fs.chmodSync(toFile, 0o600);
        moved.push({ source: fromFile, destination: toFile });
      }
      fs.rmdirSync(source);
    }
  } catch (error) {
    const prior = moved.length ? ` Already moved: ${moved.map(({ source, destination }) => `${source} -> ${destination}`).join('; ')}.` : '';
    throw new Error(`Private Live state migration stopped: ${error.message}.${prior}`, { cause: error });
  }
  return moved;
}

export function getLivePrivateDir(cwd = process.cwd(), options = {}) {
  migrateLegacyLivePrivateArtifacts(cwd, options);
  return privateLiveDataPath(cwd, options);
}

function writePrivateJsonAtomic(filePath, value) {
  const tempPath = filePath + '.' + randomUUID() + '.tmp';
  try {
    fs.writeFileSync(tempPath, JSON.stringify(value), { flag: 'wx', mode: 0o600 });
    fs.renameSync(tempPath, filePath);
  } catch (error) {
    try { fs.unlinkSync(tempPath); } catch {}
    throw error;
  }
}

export function getLegacyLiveServerPath(cwd = process.cwd(), options = {}) {
  return path.join(resolveProjectRoot(cwd, options), '.impeccable-live.json');
}

export function readLiveServerInfo(cwd = process.cwd(), options = {}) {
  for (const filePath of [getLiveServerPath(cwd, options), getLegacyLiveServerPath(cwd, options)]) {
    try {
      const info = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
      if (info && typeof info.pid === 'number' && !isLiveServerPidReachable(info.pid)) {
        try { fs.unlinkSync(filePath); } catch {}
        try { fs.unlinkSync(getLiveControllerPath(cwd, options)); } catch {}
        continue;
      }
      if (info && !info.token) {
        try {
          const privateInfo = JSON.parse(fs.readFileSync(getLiveControllerPath(cwd, options), 'utf8'));
          if (privateInfo.pid === info.pid && Number(privateInfo.port) === Number(info.port)) {
            info.token = privateInfo.token;
          }
        } catch { /* missing private controller record is handled by callers */ }
      }
      return { info, path: filePath };
    } catch {
      /* try next */
    }
  }
  return null;
}

export function isLiveServerPidReachable(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // ESRCH means "no such process". EPERM means the process exists but this
    // user cannot signal it, so the live server info is still valid.
    return err?.code !== 'ESRCH';
  }
}

export function writeLiveServerInfo(cwd = process.cwd(), info, options = {}) {
  const filePath = getLiveServerPath(cwd, options);
  const controllerPath = getLiveControllerPath(cwd, options);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  ensurePrivateControllerDirectory(controllerPath);
  // The dev server may expose arbitrary project files. Never put the
  // controller credential in app-root server.json, even at mode 0600: that
  // server runs as the same user. Keep it in a private OS-temp directory.
  writePrivateJsonAtomic(controllerPath, { pid: info.pid, port: info.port, token: info.token });
  writePrivateJsonAtomic(filePath, { pid: info.pid, port: info.port, pageToken: info.pageToken });
  try { fs.unlinkSync(getLegacyLiveServerPath(cwd, options)); } catch {}
  return filePath;
}

export function removeLiveServerInfo(cwd = process.cwd(), options = {}) {
  for (const filePath of [getLiveServerPath(cwd, options), getLegacyLiveServerPath(cwd, options), getLiveControllerPath(cwd, options)]) {
    try { fs.unlinkSync(filePath); } catch {}
  }
}

/**
 * Session IDs become path segments (journals, snapshots, accept receipts,
 * preview manifests, generated component dirs). They arrive from CLI `--id`
 * arguments and HTTP payloads, so anything containing a separator or `..` must
 * be rejected before it reaches path.join, which would happily escape
 * `.impeccable/live/`. Real IDs are 8 hex chars; the tests use short slugs.
 */
export function safeSessionId(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(id)) {
    throw new Error('invalid session id: ' + id);
  }
  return id;
}

export function getLiveSessionsDir(cwd = process.cwd(), options = {}) {
  return path.join(getLivePrivateDir(cwd, options), 'sessions');
}

export function getLegacyLiveSessionsDir(cwd = process.cwd(), options = {}) {
  return path.join(resolveProjectRoot(cwd, options), '.impeccable-live', 'sessions');
}

export function getLiveAnnotationsDir(cwd = process.cwd(), options = {}) {
  return path.join(getLiveDir(cwd, options), 'annotations');
}

export function getCritiqueDir(cwd = process.cwd(), options = {}) {
  return path.join(getImpeccableDir(cwd, options), CRITIQUE_DIR);
}

export function getLegacyLiveAnnotationsDir(cwd = process.cwd(), options = {}) {
  return path.join(resolveProjectRoot(cwd, options), '.impeccable-live', 'annotations');
}

function firstExisting(paths) {
  return paths.find((filePath) => fs.existsSync(filePath)) || null;
}
