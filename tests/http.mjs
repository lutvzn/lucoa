// Runs inside the test container with Bun (WebSocket header support).
import assert from 'node:assert/strict';

const origin = 'http://127.0.0.1:7317';
const token = process.env.OVIS_TOKEN;
assert.ok(token);
const request = (path, options = {}) => fetch(`${origin}${path}`, {
  ...options, signal: AbortSignal.timeout(15000),
});
const json = async (path, options = {}) => {
  const response = await request(path, options);
  assert.equal(response.status, 200, `unexpected HTTP status for ${path}: ${response.status}`);
  return response.json();
};
const page = await request('/');
assert.equal(page.status, 200);
assert.match(await page.text(), /<html/i);
const health = await json('/api/health');
assert.equal(health.ok, true);
assert.equal(health.auth.required, true);
assert.equal(health.herdr.runtime, 'herdr-core');
for (const path of ['/api/session', '/api/agent-catalog', '/ws']) {
  assert.equal((await request(path)).status, 401, `anonymous access allowed: ${path}`);
}
await new Promise((resolve, reject) => {
  const socket = new WebSocket('ws://127.0.0.1:7317/ws', { headers: { Origin: origin } });
  const timer = setTimeout(() => { socket.close(); reject(new Error('anonymous WebSocket did not reject')); }, 5000);
  socket.addEventListener('open', () => { clearTimeout(timer); socket.close(); reject(new Error('anonymous WebSocket accepted')); });
  socket.addEventListener('error', () => { clearTimeout(timer); resolve(); });
});
assert.equal((await request('/api/session', { headers: {
  'X-Forwarded-For': '127.0.0.1', 'X-Forwarded-Proto': 'https',
  'Tailscale-User-Login': 'owner@example.invalid', 'X-Portal-User': 'owner',
}})).status, 401, 'spoofed proxy identity bypassed auth');
const badLogin = await request('/api/auth', {
  method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
  body: JSON.stringify({ token: 'deliberately-wrong-smoke-token' }),
});
assert.equal(badLogin.status, 401);
const login = await request('/api/auth', {
  method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin },
  body: JSON.stringify({ token }),
});
assert.equal(login.status, 204);
const cookie = login.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
assert.ok(cookie);
const headers = { Cookie: cookie, Origin: origin, 'Content-Type': 'application/json' };
const authenticatedHealth = await json('/api/health', { headers });
assert.equal(authenticatedHealth.security.token_configured, true);
assert.equal(authenticatedHealth.herdr.runtime, 'herdr-core');
const updates = await json('/api/updates', { headers });
assert.equal(updates.managed, false, 'image should not use the managed in-app updater');

const catalog = await json('/api/agent-catalog', { headers });
// Check actual installed detection, not just presence in the static catalog.
for (const id of ['claude', 'pi']) {
  const row = catalog.agents.find(agent => agent.id === id);
  assert.ok(row, `missing agent: ${id}`);
  assert.equal(row.state.installed, true, `agent not installed: ${id}`);
  assert.equal(row.state.on_path, true, `agent not on PATH: ${id}`);
  assert.equal(row.state.version_error, null, `agent version probe failed: ${id}`);
}

const created = await json('/api/workspace/create', {
  method: 'POST', headers, body: JSON.stringify({ cwd: '/workspace', label: 'lucoa smoke' }),
});
assert.ok(created.pane_id);
assert.ok(created.workspace_id);

async function connect() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket('ws://127.0.0.1:7317/ws', { headers });
    const messages = [];
    const timer = setTimeout(() => { socket.close(); reject(new Error('WebSocket snapshot timed out')); }, 15000);
    socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('authenticated WebSocket failed')); });
    socket.addEventListener('message', event => {
      let message;
      try { message = JSON.parse(String(event.data)); } catch { return; }
      messages.push(message);
      if (message.type === 'snapshot') {
        clearTimeout(timer);
        resolve({ socket, messages });
      }
    });
  });
}
async function waitFor(connection, predicate, description) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (predicate(connection.messages)) return;
    await Bun.sleep(100);
  }
  throw new Error(`timed out: ${description}`);
}
const attach = connection => connection.socket.send(JSON.stringify({
  type: 'attach', pane_id: created.pane_id, cols: 100, rows: 30,
}));
const outputContains = marker => messages => messages
  .filter(message => message.type === 'pty-data' && message.pane_id === created.pane_id)
  .map(message => message.data).join('').includes(marker);
const first = await connect();
attach(first);
await waitFor(first, messages => messages.some(message => message.type === 'input-ready' && message.ready !== false), 'terminal readiness');
first.socket.send(JSON.stringify({ type: 'input', pane_id: created.pane_id,
  text: "printf '%s%s\\n' LUCOA_ WS_OK; sleep 3; printf '%s%s\\n' LUCOA_ RECONNECT_OK\r" }));
await waitFor(first, outputContains('LUCOA_WS_OK'), 'live terminal output');
first.socket.close();
await Bun.sleep(4000);
const second = await connect();
assert.ok(second.messages.some(message => JSON.stringify(message).includes(created.pane_id)));
attach(second);
await waitFor(second, outputContains('LUCOA_RECONNECT_OK'), 'task output after disconnected browser');
second.socket.close();
await json('/api/workspace/close', {
  method: 'POST', headers, body: JSON.stringify({ workspace_id: created.workspace_id }),
});
console.log('PASS: assets, backend health, API/WebSocket auth, proxy-header rejection, agent detection, login, workspace creation, live terminal I/O and reconnect');
