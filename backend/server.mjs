import http from 'node:http';
import crypto from 'node:crypto';
import Database from 'better-sqlite3';

const PORT = Number(process.env.PORT || 8787);
const DATA_PATH = process.env.DATA_PATH || './guest-auth.sqlite3';
const SESSION_SECRET = process.env.SESSION_SECRET;
const ACCESS_TTL_SECONDS = Number(process.env.ACCESS_TTL_SECONDS || 3600);
const REFRESH_TTL_SECONDS = Number(process.env.REFRESH_TTL_SECONDS || 60 * 60 * 24 * 90);

if (!SESSION_SECRET || SESSION_SECRET.length < 32) {
  throw new Error('SESSION_SECRET must be at least 32 characters');
}

const db = new Database(DATA_PATH);
db.pragma('journal_mode = WAL');
db.exec(`
CREATE TABLE IF NOT EXISTS guest_users (
  id TEXT PRIMARY KEY,
  install_hash TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS refresh_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(user_id) REFERENCES guest_users(id)
);
CREATE INDEX IF NOT EXISTS idx_refresh_user ON refresh_tokens(user_id);
`);

const findGuest = db.prepare('SELECT * FROM guest_users WHERE install_hash = ?');
const insertGuest = db.prepare('INSERT INTO guest_users (id, install_hash, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)');
const insertRefresh = db.prepare('INSERT INTO refresh_tokens (token_hash, user_id, created_at, expires_at, revoked) VALUES (?, ?, ?, ?, 0)');
const findRefresh = db.prepare('SELECT * FROM refresh_tokens WHERE token_hash = ? AND revoked = 0');
const revokeRefresh = db.prepare('UPDATE refresh_tokens SET revoked = 1 WHERE token_hash = ?');

function b64url(value) {
  return Buffer.from(value).toString('base64url');
}

function hmac(value) {
  return crypto.createHmac('sha256', SESSION_SECRET).update(value).digest('hex');
}

function signAccessToken(userId) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({
    iss: 'mbp-guest-auth',
    sub: userId,
    kind: 'guest',
    iat: now,
    exp: now + ACCESS_TTL_SECONDS
  }));
  const sig = crypto.createHmac('sha256', SESSION_SECRET).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${sig}`;
}

function issueRefreshToken(userId) {
  const token = crypto.randomBytes(32).toString('base64url');
  const tokenHash = hmac(`refresh:${token}`);
  const now = Math.floor(Date.now() / 1000);
  insertRefresh.run(tokenHash, userId, now, now + REFRESH_TTL_SECONDS);
  return token;
}

function json(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': data.length,
    'cache-control': 'no-store'
  });
  res.end(data);
}

async function readJson(req) {
  let total = 0;
  const chunks = [];
  for await (const chunk of req) {
    total += chunk.length;
    if (total > 32 * 1024) throw new Error('payload_too_large');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}

function normalizeInstallId(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (trimmed.length < 16 || trimmed.length > 128) return null;
  if (!/^[A-Za-z0-9._:-]+$/.test(trimmed)) return null;
  return trimmed;
}

function bootstrapGuest(installId) {
  const installHash = hmac(`install:${installId}`);
  let guest = findGuest.get(installHash);
  if (!guest) {
    const now = Math.floor(Date.now() / 1000);
    const userId = `guest_${crypto.randomUUID().replaceAll('-', '')}`;
    const displayName = `Guest ${userId.slice(-6)}`;
    insertGuest.run(userId, installHash, displayName, now, now);
    guest = findGuest.get(installHash);
  }

  return {
    user: {
      id: guest.id,
      username: guest.id,
      nickname: guest.display_name,
      kind: 'guest'
    },
    session: {
      access_token: signAccessToken(guest.id),
      refresh_token: issueRefreshToken(guest.id),
      token_type: 'Bearer',
      expires_in: ACCESS_TTL_SECONDS
    }
  };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

    if (req.method === 'GET' && url.pathname === '/health') {
      return json(res, 200, { ok: true, service: 'mbp-guest-auth' });
    }

    if (req.method === 'POST' && url.pathname === '/v1/guest/bootstrap') {
      const body = await readJson(req);
      const installId = normalizeInstallId(body.install_id);
      if (!installId) return json(res, 400, { error: 'invalid_install_id' });
      return json(res, 200, bootstrapGuest(installId));
    }

    if (req.method === 'POST' && url.pathname === '/v1/guest/refresh') {
      const body = await readJson(req);
      if (typeof body.refresh_token !== 'string' || body.refresh_token.length < 20) {
        return json(res, 400, { error: 'invalid_refresh_token' });
      }
      const tokenHash = hmac(`refresh:${body.refresh_token}`);
      const record = findRefresh.get(tokenHash);
      const now = Math.floor(Date.now() / 1000);
      if (!record || record.expires_at <= now) {
        return json(res, 401, { error: 'refresh_token_expired_or_invalid' });
      }
      revokeRefresh.run(tokenHash);
      return json(res, 200, {
        user_id: record.user_id,
        access_token: signAccessToken(record.user_id),
        refresh_token: issueRefreshToken(record.user_id),
        token_type: 'Bearer',
        expires_in: ACCESS_TTL_SECONDS
      });
    }

    return json(res, 404, { error: 'not_found' });
  } catch (error) {
    console.error(error);
    return json(res, error?.message === 'payload_too_large' ? 413 : 500, { error: 'server_error' });
  }
});

server.listen(PORT, () => {
  console.log(`mbp-guest-auth listening on :${PORT}`);
});
