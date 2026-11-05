#!/usr/bin/env node
/*
 * Minimal, hardened file server for the generated planet and moon files.
 *
 * Security properties (compared with the original upstream script):
 *  - only allow-listed file names are served (planet, *.moon)
 *  - the resolved real path must stay inside DIST_DIR (no path traversal)
 *  - the download key is compared in constant time
 *  - the key is accepted via Authorization/X-Api-Key headers by default;
 *    the legacy ?key= query string is opt-in only (ALLOW_QUERY_KEY=1)
 *  - keys are 32 random bytes and persisted with mode 0600
 *  - failed authentication is rate limited per source address
 *  - TLS is supported and enabled by default in the container entrypoint
 *
 * GPLv3 - see LICENSE.
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');

const DIST_DIR = path.resolve(process.env.DIST_DIR || '/app/dist');
const PORT = parseInt(process.env.FILE_SERVER_PORT || '3000', 10);
const BIND = process.env.FILE_SERVER_BIND || '0.0.0.0';
const TLS_ENABLED = process.env.TLS_ENABLED === '1';
const TLS_CERT = process.env.TLS_CERT || '/app/config/tls/fullchain.pem';
const TLS_KEY = process.env.TLS_KEY || '/app/config/tls/privkey.pem';
const ALLOW_QUERY_KEY = process.env.ALLOW_QUERY_KEY === '1';
const TRUST_PROXY = process.env.TRUST_PROXY === '1';
const KEY_FILE = path.resolve(process.env.FILE_KEY_FILE || '/app/config/file_server.key');
const MAX_FAILURES = 20;
const FAILURE_WINDOW_MS = 15 * 60 * 1000;

if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  console.error('file-server: invalid FILE_SERVER_PORT');
  process.exit(1);
}

let DIST_REAL;
try {
  DIST_REAL = fs.realpathSync(DIST_DIR);
} catch (err) {
  console.error('file-server: DIST_DIR is not accessible: ' + err.message);
  process.exit(1);
}

function loadKey() {
  const fromEnv = process.env.FILE_KEY;
  if (fromEnv) {
    if (fromEnv.length < 32) {
      console.error('file-server: FILE_KEY must be at least 32 characters');
      process.exit(1);
    }
    return fromEnv;
  }

  try {
    const stored = fs.readFileSync(KEY_FILE, 'utf8').trim();
    if (stored.length >= 32) return stored;
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.error('file-server: cannot read key file: ' + err.message);
      process.exit(1);
    }
  }

  const key = crypto.randomBytes(32).toString('hex');
  fs.mkdirSync(path.dirname(KEY_FILE), { recursive: true, mode: 0o700 });
  fs.writeFileSync(KEY_FILE, key + '\n', { encoding: 'utf8', mode: 0o600 });
  fs.chmodSync(KEY_FILE, 0o600);
  console.log('file-server: generated a new download key in ' + KEY_FILE);
  return key;
}

const KEY = loadKey();
const KEY_DIGEST = crypto.createHash('sha256').update(KEY, 'utf8').digest();

const failures = new Map();

function clientIp(req) {
  if (TRUST_PROXY) {
    const xff = req.headers['x-forwarded-for'];
    if (typeof xff === 'string' && xff.length > 0) return xff.split(',')[0].trim();
  }
  return (req.socket && req.socket.remoteAddress) || 'unknown';
}

function isThrottled(ip) {
  const record = failures.get(ip);
  return !!record && record.reset > Date.now() && record.count >= MAX_FAILURES;
}

function recordFailure(ip) {
  const now = Date.now();
  let record = failures.get(ip);
  if (!record || record.reset <= now) {
    record = { count: 0, reset: now + FAILURE_WINDOW_MS };
    failures.set(ip, record);
  }
  record.count += 1;
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, record] of failures) {
    if (record.reset <= now) failures.delete(ip);
  }
}, 5 * 60 * 1000).unref();

function safeEqual(candidate) {
  if (typeof candidate !== 'string') return false;
  const digest = crypto.createHash('sha256').update(candidate, 'utf8').digest();
  return crypto.timingSafeEqual(digest, KEY_DIGEST);
}

function presentedKey(req) {
  const auth = req.headers.authorization;
  if (typeof auth === 'string' && /^Bearer\s+/i.test(auth)) {
    return auth.replace(/^Bearer\s+/i, '').trim();
  }
  const apiKey = req.headers['x-api-key'];
  if (typeof apiKey === 'string') return apiKey.trim();
  if (ALLOW_QUERY_KEY) {
    try {
      return new URL(req.url, 'http://localhost').searchParams.get('key');
    } catch (err) {
      return null;
    }
  }
  return null;
}

function send(res, status, body, headers) {
  const payload = Buffer.from(body, 'utf8');
  res.writeHead(status, Object.assign({
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': payload.length,
    'X-Content-Type-Options': 'nosniff',
    'Cache-Control': 'no-store'
  }, headers || {}));
  res.end(payload);
}

function allowedName(name) {
  if (name === 'planet') return true;
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.moon$/.test(name);
}

async function resolveFile(urlPath) {
  let name;
  try {
    name = decodeURIComponent(urlPath.replace(/^\/+/, ''));
  } catch (err) {
    return null;
  }
  if (!allowedName(name) || name.includes('/') || name.includes('\\')) return null;

  const candidate = path.join(DIST_REAL, name);
  let real;
  try {
    real = await fs.promises.realpath(candidate);
  } catch (err) {
    return null;
  }
  if (real !== path.join(DIST_REAL, name)) return null;
  return real;
}

async function handle(req, res) {
  const ip = clientIp(req);

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return send(res, 405, 'Method Not Allowed\n', { Allow: 'GET, HEAD' });
  }

  if (req.url === '/healthz') {
    return send(res, 200, 'ok\n');
  }

  if (isThrottled(ip)) {
    return send(res, 429, 'Too Many Requests\n', { 'Retry-After': '900' });
  }

  if (!safeEqual(presentedKey(req))) {
    recordFailure(ip);
    return send(res, 401, 'Unauthorized\n', {
      'WWW-Authenticate': 'Bearer realm="planet"'
    });
  }

  const pathname = (() => {
    try {
      return new URL(req.url, 'http://localhost').pathname;
    } catch (err) {
      return '/';
    }
  })();

  if (pathname === '/') {
    return send(res, 200,
      'ZeroTier planet file server\n\n' +
      'GET /planet          (Authorization: Bearer <key>)\n' +
      'GET /<name>.moon     (Authorization: Bearer <key>)\n' +
      'GET /healthz\n',
      { 'Content-Type': 'text/plain; charset=utf-8' });
  }

  const file = await resolveFile(pathname);
  if (!file) return send(res, 404, 'Not Found\n');

  let stat;
  try {
    stat = await fs.promises.stat(file);
  } catch (err) {
    return send(res, 404, 'Not Found\n');
  }
  if (!stat.isFile()) return send(res, 404, 'Not Found\n');

  const headers = {
    'Content-Type': 'application/octet-stream',
    'Content-Length': stat.size,
    'Content-Disposition': 'attachment; filename="' + path.basename(file) + '"',
    'Cache-Control': 'private, max-age=300',
    'X-Content-Type-Options': 'nosniff'
  };

  if (req.method === 'HEAD') {
    res.writeHead(200, headers);
    return res.end();
  }

  res.writeHead(200, headers);
  fs.createReadStream(file)
    .on('error', () => res.destroy())
    .pipe(res);
}

function createServer() {
  if (!TLS_ENABLED) {
    return http.createServer((req, res) => {
      handle(req, res).catch(() => send(res, 500, 'Internal Server Error\n'));
    });
  }

  return https.createServer({
    cert: fs.readFileSync(TLS_CERT),
    key: fs.readFileSync(TLS_KEY),
    minVersion: 'TLSv1.2'
  }, (req, res) => {
    handle(req, res).catch(() => send(res, 500, 'Internal Server Error\n'));
  });
}

let server;
try {
  server = createServer();
} catch (err) {
  console.error('file-server: cannot start: ' + err.message);
  process.exit(1);
}

server.headersTimeout = 15000;
server.requestTimeout = 30000;
server.keepAliveTimeout = 5000;

server.listen(PORT, BIND, () => {
  console.log('file-server: listening on ' + (TLS_ENABLED ? 'https' : 'http') + '://' + BIND + ':' + PORT);
  console.log('file-server: serving ' + DIST_REAL);
});

function shutdown(signal) {
  console.log('file-server: received ' + signal + ', shutting down');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
