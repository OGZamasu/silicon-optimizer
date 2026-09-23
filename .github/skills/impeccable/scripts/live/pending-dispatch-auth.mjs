import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { getLivePrivateDir, grantsGroupOrOtherAccess } from '../lib/impeccable-paths.mjs';

const AUTH_FIELD = 'privateDispatchMac';

function unsignedEvent(event) {
  const { [AUTH_FIELD]: _suppliedMac, token: _suppliedToken, ...unsigned } = event;
  return unsigned;
}

export function createPendingDispatchAuth(cwd = process.cwd()) {
  const keyPath = path.join(getLivePrivateDir(cwd), 'pending-dispatch.key');
  try {
    fs.writeFileSync(keyPath, randomBytes(32), { flag: 'wx', mode: 0o600 });
  } catch (error) {
    if (error?.code !== 'EEXIST') throw error;
  }
  const stat = fs.lstatSync(keyPath);
  if (!stat.isFile() || stat.isSymbolicLink() || grantsGroupOrOtherAccess(stat)) {
    throw new Error(`Private Live dispatch key is unsafe: ${keyPath}`);
  }
  const key = fs.readFileSync(keyPath);
  if (key.length !== 32) throw new Error(`Private Live dispatch key is invalid: ${keyPath}`);

  function macFor(event) {
    return createHmac('sha256', key).update(JSON.stringify(unsignedEvent(event))).digest();
  }

  return {
    sign(event) {
      const unsigned = unsignedEvent(event);
      return { ...unsigned, [AUTH_FIELD]: macFor(unsigned).toString('hex') };
    },
    verify(event) {
      if (!event || typeof event !== 'object' || typeof event[AUTH_FIELD] !== 'string'
          || !/^[a-f0-9]{64}$/.test(event[AUTH_FIELD])) return false;
      return timingSafeEqual(Buffer.from(event[AUTH_FIELD], 'hex'), macFor(event));
    },
  };
}
