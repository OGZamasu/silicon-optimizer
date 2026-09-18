import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const NOFOLLOW = fs.constants.O_NOFOLLOW || 0;

export class SecurityBoundaryError extends Error {
  constructor(message, code = 'SECURITY_BOUNDARY') {
    super(message);
    this.name = 'SecurityBoundaryError';
    this.code = code;
  }
}

function canonical(filePath) {
  const realpath = fs.realpathSync.native || fs.realpathSync;
  return realpath(filePath);
}

export function isPathInside(root, candidate, { allowRoot = false } = {}) {
  const relative = path.relative(root, candidate);
  if (!relative) return allowRoot;
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function requireContained(root, candidate, { allowRoot = false } = {}) {
  if (!isPathInside(root, candidate, { allowRoot })) {
    throw new SecurityBoundaryError('path escapes the authorized project root', 'PATH_OUTSIDE_ROOT');
  }
}

function requireNoSymlinkComponents(lexicalRoot, absolutePath, { allowMissingLeaf = false } = {}) {
  const relative = path.relative(lexicalRoot, absolutePath);
  requireContained(lexicalRoot, absolutePath, { allowRoot: true });
  if (!relative) return;

  const parts = relative.split(path.sep).filter(Boolean);
  let current = lexicalRoot;
  for (let index = 0; index < parts.length; index += 1) {
    current = path.join(current, parts[index]);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (error?.code === 'ENOENT' && allowMissingLeaf && index === parts.length - 1) return;
      throw error;
    }
    if (stat.isSymbolicLink()) {
      throw new SecurityBoundaryError('symbolic links are not authorized for this operation', 'SYMLINK_REJECTED');
    }
  }
}

/**
 * Resolve a caller-supplied path to a concrete object strictly below root.
 * Every existing component is lstat'd and the final canonical object is
 * checked again, so lexical traversal, component-prefix collisions, and
 * symlink escapes all fail before an open.
 */
export function resolvePathInside(root, candidate, {
  mustExist = true,
  kind = null,
  allowRoot = false,
  allowAbsolute = true,
} = {}) {
  if (typeof candidate !== 'string' || candidate.length === 0 || candidate.includes('\0')) {
    throw new SecurityBoundaryError('path must be a non-empty string without NUL bytes', 'INVALID_PATH');
  }
  if (!allowAbsolute && path.isAbsolute(candidate)) {
    throw new SecurityBoundaryError('absolute paths are not authorized', 'ABSOLUTE_PATH_REJECTED');
  }

  const lexicalRoot = path.resolve(root);
  const rootStat = fs.statSync(lexicalRoot);
  if (!rootStat.isDirectory()) {
    throw new SecurityBoundaryError('authorized root is not a directory', 'INVALID_ROOT');
  }
  const canonicalRoot = canonical(lexicalRoot);
  let absolutePath = path.isAbsolute(candidate)
    ? path.resolve(candidate)
    : path.resolve(lexicalRoot, candidate);
  let componentRoot = lexicalRoot;
  if (!isPathInside(lexicalRoot, absolutePath, { allowRoot })) {
    // macOS exposes /var through /private/var. An already-existing absolute
    // argument may therefore name the same object under a different system
    // alias even though process.cwd() is canonical. Canonicalize that alias
    // only after the normal lexical check fails; paths lexically below root
    // still go through component-by-component symlink rejection.
    if (!path.isAbsolute(candidate) || !mustExist) requireContained(lexicalRoot, absolutePath, { allowRoot });
    const canonicalAlias = canonical(absolutePath);
    requireContained(canonicalRoot, canonicalAlias, { allowRoot });
    absolutePath = canonicalAlias;
    componentRoot = canonicalRoot;
  }

  if (!mustExist) {
    requireNoSymlinkComponents(lexicalRoot, absolutePath, { allowMissingLeaf: true });
    const parent = path.dirname(absolutePath);
    const canonicalParent = canonical(parent);
    requireContained(canonicalRoot, canonicalParent, { allowRoot: true });
    return absolutePath;
  }

  requireNoSymlinkComponents(componentRoot, absolutePath);
  const canonicalPath = canonical(absolutePath);
  requireContained(canonicalRoot, canonicalPath, { allowRoot });
  const stat = fs.lstatSync(absolutePath);
  if (kind === 'file' && !stat.isFile()) {
    throw new SecurityBoundaryError('authorized path is not a regular file', 'NOT_REGULAR_FILE');
  }
  if (kind === 'directory' && !stat.isDirectory()) {
    throw new SecurityBoundaryError('authorized path is not a directory', 'NOT_DIRECTORY');
  }
  return absolutePath;
}

/**
 * Authorize a future file path whose nested parent directories may not exist
 * yet. Existing components are still link-free and the closest existing
 * ancestor is canonicalized inside root. This is for registering a path that
 * another trusted workflow will create later, not for opening it directly.
 */
export function resolveFuturePathInside(root, candidate, { allowAbsolute = true } = {}) {
  if (typeof candidate !== 'string' || candidate.length === 0 || candidate.includes('\0')) {
    throw new SecurityBoundaryError('path must be a non-empty string without NUL bytes', 'INVALID_PATH');
  }
  if (!allowAbsolute && path.isAbsolute(candidate)) {
    throw new SecurityBoundaryError('absolute paths are not authorized', 'ABSOLUTE_PATH_REJECTED');
  }
  const lexicalRoot = path.resolve(root);
  const rootStat = fs.statSync(lexicalRoot);
  if (!rootStat.isDirectory()) throw new SecurityBoundaryError('authorized root is not a directory', 'INVALID_ROOT');
  const canonicalRoot = canonical(lexicalRoot);
  const absolutePath = path.isAbsolute(candidate) ? path.resolve(candidate) : path.resolve(lexicalRoot, candidate);
  requireContained(lexicalRoot, absolutePath);

  let current = lexicalRoot;
  for (const part of path.relative(lexicalRoot, absolutePath).split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    try {
      const stat = fs.lstatSync(current);
      if (stat.isSymbolicLink()) {
        throw new SecurityBoundaryError('symbolic links are not authorized for this operation', 'SYMLINK_REJECTED');
      }
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
      break;
    }
  }
  let existing = current;
  while (!fs.existsSync(existing)) existing = path.dirname(existing);
  requireContained(canonicalRoot, canonical(existing), { allowRoot: true });
  return absolutePath;
}

export function ensureDirectoryInside(root, candidate, { mode = 0o700 } = {}) {
  if (typeof candidate !== 'string' || candidate.length === 0 || candidate.includes('\0')) {
    throw new SecurityBoundaryError('directory path must be a non-empty string', 'INVALID_PATH');
  }
  const lexicalRoot = path.resolve(root);
  const absolutePath = path.isAbsolute(candidate)
    ? path.resolve(candidate)
    : path.resolve(lexicalRoot, candidate);
  requireContained(lexicalRoot, absolutePath, { allowRoot: true });
  const relative = path.relative(lexicalRoot, absolutePath);
  let current = lexicalRoot;
  for (const part of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    try {
      const stat = fs.lstatSync(current);
      if (stat.isSymbolicLink() || !stat.isDirectory()) {
        throw new SecurityBoundaryError('managed directory contains a link or non-directory component', 'UNSAFE_DIRECTORY');
      }
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
      fs.mkdirSync(current, { mode });
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) {
        throw new SecurityBoundaryError('managed directory creation did not produce a regular directory', 'UNSAFE_DIRECTORY');
      }
    }
  }
  return resolvePathInside(lexicalRoot, absolutePath, { kind: 'directory', allowRoot: true });
}

export function readFileInside(root, candidate, { encoding = null, maxBytes = null } = {}) {
  const filePath = resolvePathInside(root, candidate, { kind: 'file' });
  const fd = fs.openSync(filePath, fs.constants.O_RDONLY | NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) throw new SecurityBoundaryError('opened object is not a regular file', 'NOT_REGULAR_FILE');
    if (Number.isFinite(maxBytes) && stat.size > maxBytes) {
      throw new SecurityBoundaryError('file exceeds the authorized byte budget', 'FILE_TOO_LARGE');
    }
    return fs.readFileSync(fd, encoding ? { encoding } : undefined);
  } finally {
    fs.closeSync(fd);
  }
}

export function atomicWriteFileInside(root, candidate, data, {
  encoding = 'utf8',
  mode = null,
  allowCreate = true,
} = {}) {
  const lexicalRoot = path.resolve(root);
  const absolutePath = path.isAbsolute(candidate) ? path.resolve(candidate) : path.resolve(lexicalRoot, candidate);
  const exists = fs.existsSync(absolutePath);
  if (!exists && !allowCreate) {
    throw new SecurityBoundaryError('authorized destination does not exist', 'FILE_NOT_FOUND');
  }
  if (exists) resolvePathInside(lexicalRoot, absolutePath, { kind: 'file' });
  else resolvePathInside(lexicalRoot, absolutePath, { mustExist: false });
  const parent = resolvePathInside(lexicalRoot, path.dirname(absolutePath), { kind: 'directory', allowRoot: true });
  const existingMode = exists ? (fs.lstatSync(absolutePath).mode & 0o777) : null;
  const writeMode = mode ?? existingMode ?? 0o600;
  const tempPath = path.join(parent, `.${path.basename(absolutePath)}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`);
  let fd;
  try {
    fd = fs.openSync(tempPath, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | NOFOLLOW, writeMode);
    fs.writeFileSync(fd, data, encoding ? { encoding } : undefined);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = null;
    resolvePathInside(lexicalRoot, parent, { kind: 'directory', allowRoot: true });
    if (fs.existsSync(absolutePath)) resolvePathInside(lexicalRoot, absolutePath, { kind: 'file' });
    fs.renameSync(tempPath, absolutePath);
    return absolutePath;
  } finally {
    if (fd !== null && fd !== undefined) {
      try { fs.closeSync(fd); } catch {}
    }
    try { fs.unlinkSync(tempPath); } catch {}
  }
}

export function appendFileInside(root, candidate, data, {
  encoding = 'utf8',
  mode = 0o600,
  maxBytes = 8 * 1024 * 1024,
} = {}) {
  const lexicalRoot = path.resolve(root);
  const absolutePath = path.isAbsolute(candidate) ? path.resolve(candidate) : path.resolve(lexicalRoot, candidate);
  if (fs.existsSync(absolutePath)) resolvePathInside(lexicalRoot, absolutePath, { kind: 'file' });
  else resolvePathInside(lexicalRoot, absolutePath, { mustExist: false });
  const fd = fs.openSync(absolutePath, fs.constants.O_CREAT | fs.constants.O_APPEND | fs.constants.O_WRONLY | NOFOLLOW, mode);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) throw new SecurityBoundaryError('audit destination is not a regular file', 'NOT_REGULAR_FILE');
    const bytes = Buffer.byteLength(data, encoding || undefined);
    if (stat.size + bytes > maxBytes) {
      throw new SecurityBoundaryError('audit log byte budget exhausted', 'FILE_TOO_LARGE');
    }
    fs.writeFileSync(fd, data, encoding ? { encoding } : undefined);
    return absolutePath;
  } finally {
    fs.closeSync(fd);
  }
}

export function removeFileInside(root, candidate) {
  const filePath = resolvePathInside(root, candidate, { kind: 'file' });
  fs.unlinkSync(filePath);
  return filePath;
}

export function safeQuestionKey(value) {
  if (typeof value !== 'string' || !/^(?:[a-f0-9]{8,64}|[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12})$/.test(value)) {
    throw new SecurityBoundaryError('question key must be 8-64 lowercase hex characters or a canonical UUID', 'INVALID_QUESTION_KEY');
  }
  return value;
}
