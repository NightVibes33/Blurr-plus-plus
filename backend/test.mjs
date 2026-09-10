import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';

const port = 18787;
const dbPath = './guest-auth-test.sqlite3';
for (const suffix of ['', '-shm', '-wal']) {
  try { fs.unlinkSync(dbPath + suffix); } catch {}
}

const child = spawn(process.execPath, ['server.mjs'], {
  cwd: new URL('.', import.meta.url).pathname,
  env: {
    ...process.env,
    PORT: String(port),
    DATA_PATH: dbPath,
    SESSION_SECRET: 'test-only-session-secret-0123456789abcdef0123456789'
  },
  stdio: ['ignore', 'pipe', 'pipe']
});

async function waitForHealth() {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/health`);
      if (r.ok) return;
    } catch {}
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error('guest auth service did not start');
}

async function post(path, body) {
  const r = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });
  const json = await r.json();
  assert.equal(r.ok, true, JSON.stringify(json));
  return json;
}

try {
  await waitForHealth();
  const installId = 'ios-install-0123456789abcdef';
  const first = await post('/v1/guest/bootstrap', { install_id: installId });
  const second = await post('/v1/guest/bootstrap', { install_id: installId });

  assert.equal(first.user.id, second.user.id, 'same install must resolve to same guest user');
  assert.notEqual(first.session.refresh_token, second.session.refresh_token, 'sessions may rotate independently');

  const refreshed = await post('/v1/guest/refresh', {
    refresh_token: first.session.refresh_token
  });
  assert.equal(refreshed.user_id, first.user.id, 'refresh must retain same guest user');
  assert.notEqual(refreshed.refresh_token, first.session.refresh_token, 'refresh token must rotate');

  console.log(`PASS persistent guest user ${first.user.id}`);
} finally {
  child.kill('SIGTERM');
  for (const suffix of ['', '-shm', '-wal']) {
    try { fs.unlinkSync(new URL(dbPath + suffix, new URL('.', import.meta.url)).pathname); } catch {}
  }
}
