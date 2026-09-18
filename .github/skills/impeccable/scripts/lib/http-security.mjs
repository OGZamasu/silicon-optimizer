import crypto from 'node:crypto';

export const DEFAULT_JSON_BODY_LIMIT = 1024 * 1024;
export const DEFAULT_BODY_TIMEOUT_MS = 10_000;

export class HttpInputError extends Error {
  constructor(status, code, message, { closeRequest = false } = {}) {
    super(message);
    this.name = 'HttpInputError';
    this.status = status;
    this.code = code;
    this.closeRequest = closeRequest;
  }
}

export function tokenMatches(actual, expected) {
  if (typeof actual !== 'string' || typeof expected !== 'string' || !actual || !expected) return false;
  const actualHash = crypto.createHash('sha256').update(actual).digest();
  const expectedHash = crypto.createHash('sha256').update(expected).digest();
  return crypto.timingSafeEqual(actualHash, expectedHash);
}

export function requestToken(req, headerName = 'x-impeccable-token') {
  const value = req.headers[headerName.toLowerCase()];
  return Array.isArray(value) ? null : value;
}

export function requireRequestToken(req, res, expected, {
  headerName = 'x-impeccable-token',
  contentType = 'application/json',
} = {}) {
  if (tokenMatches(requestToken(req, headerName), expected)) return true;
  res.writeHead(401, { 'Content-Type': contentType });
  res.end(contentType === 'application/json'
    ? JSON.stringify({ error: 'Unauthorized' })
    : 'Unauthorized');
  return false;
}

function parseContentLength(req, maxBytes) {
  const raw = req.headers['content-length'];
  if (raw === undefined) return null;
  if (Array.isArray(raw) || !/^(?:0|[1-9]\d*)$/.test(raw)) {
    throw new HttpInputError(400, 'INVALID_CONTENT_LENGTH', 'Invalid Content-Length', { closeRequest: true });
  }
  const length = Number(raw);
  if (!Number.isSafeInteger(length)) {
    throw new HttpInputError(400, 'INVALID_CONTENT_LENGTH', 'Invalid Content-Length', { closeRequest: true });
  }
  if (length > maxBytes) {
    throw new HttpInputError(413, 'PAYLOAD_TOO_LARGE', 'Payload too large', { closeRequest: true });
  }
  return length;
}

export async function readBoundedBody(req, {
  maxBytes = DEFAULT_JSON_BODY_LIMIT,
  timeoutMs = DEFAULT_BODY_TIMEOUT_MS,
  contentType = null,
} = {}) {
  if (contentType) {
    const mediaType = String(req.headers['content-type'] || '').split(';', 1)[0].trim().toLowerCase();
    if (mediaType !== contentType) {
      throw new HttpInputError(415, 'UNSUPPORTED_MEDIA_TYPE', `Content-Type must be ${contentType}`);
    }
  }
  const contentLength = parseContentLength(req, maxBytes);

  return await new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      req.off('data', onData);
      req.off('end', onEnd);
      req.off('aborted', onAborted);
      req.off('error', onError);
      fn(value);
    };
    const fail = (error) => finish(reject, error);
    const timer = setTimeout(() => {
      req.pause();
      fail(new HttpInputError(408, 'REQUEST_TIMEOUT', 'Request body timed out', { closeRequest: true }));
    }, timeoutMs);
    timer.unref?.();

    const onData = (chunk) => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buffer.length;
      if (total > maxBytes) {
        req.pause();
        fail(new HttpInputError(413, 'PAYLOAD_TOO_LARGE', 'Payload too large', { closeRequest: true }));
        return;
      }
      chunks.push(buffer);
    };
    const onEnd = () => {
      if (contentLength !== null && total !== contentLength) {
        fail(new HttpInputError(400, 'CONTENT_LENGTH_MISMATCH', 'Content-Length did not match the request body'));
        return;
      }
      finish(resolve, Buffer.concat(chunks, total));
    };
    const onAborted = () => fail(new HttpInputError(400, 'REQUEST_ABORTED', 'Request aborted'));
    const onError = () => fail(new HttpInputError(400, 'REQUEST_ERROR', 'Request failed'));

    req.on('data', onData);
    req.on('end', onEnd);
    req.on('aborted', onAborted);
    req.on('error', onError);
  });
}

export async function readBoundedJson(req, {
  maxBytes = DEFAULT_JSON_BODY_LIMIT,
  timeoutMs = DEFAULT_BODY_TIMEOUT_MS,
  requireContentType = true,
} = {}) {
  const buffer = await readBoundedBody(req, {
    maxBytes,
    timeoutMs,
    contentType: requireContentType ? 'application/json' : null,
  });
  try { return JSON.parse(buffer.toString('utf8')); }
  catch { throw new HttpInputError(400, 'INVALID_JSON', 'Invalid JSON'); }
}

export function sendHttpInputError(req, res, error) {
  if (res.writableEnded || res.destroyed) return;
  const status = Number.isInteger(error?.status) ? error.status : 400;
  res.writeHead(status, { 'Content-Type': 'application/json', Connection: error?.closeRequest ? 'close' : 'keep-alive' });
  res.end(JSON.stringify({ error: error?.code || 'BAD_REQUEST', message: error?.message || 'Bad request' }));
  if (error?.closeRequest) res.once('finish', () => req.destroy());
}

export function validateLoopbackRequest(req, res, { port, token, allowQueryToken = false } = {}) {
  const expectedHost = `127.0.0.1:${port}`;
  const expectedOrigin = `http://${expectedHost}`;
  if (req.headers.host !== expectedHost) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('Forbidden Host');
    return false;
  }
  const origin = req.headers.origin;
  if (origin && origin !== expectedOrigin) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('Forbidden Origin');
    return false;
  }
  const fetchSite = req.headers['sec-fetch-site'];
  if (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none') {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('Forbidden request context');
    return false;
  }
  if (tokenMatches(requestToken(req, 'x-impeccable-question'), token)) return true;
  if (allowQueryToken) {
    try {
      const url = new URL(req.url, expectedOrigin);
      if (tokenMatches(url.searchParams.get('token'), token)) return true;
    } catch {}
  }
  res.writeHead(401, { 'Content-Type': 'text/plain' });
  res.end('Unauthorized');
  return false;
}

export function applyDefensiveServerTimeouts(server) {
  server.headersTimeout = 5_000;
  server.requestTimeout = 15_000;
  server.keepAliveTimeout = 5_000;
  server.maxRequestsPerSocket = 100;
  return server;
}
