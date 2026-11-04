// Optional bounded readiness soak; no provider requests and no published ports.
import { readFileSync, readdirSync } from 'node:fs';
import assert from 'node:assert/strict';

const seconds = Number(process.env.LUCOA_SOAK_SECONDS);
assert.ok(Number.isInteger(seconds) && seconds > 0 && seconds <= 86400, 'soak duration must be 1..86400 seconds');
const pid = readdirSync('/proc').find(entry => {
  if (!/^\d+$/.test(entry)) return false;
  try {
    const args = readFileSync(`/proc/${entry}/cmdline`, 'utf8').split('\0');
    return args[0]?.endsWith('bun') && args.includes('/opt/lucoa/ovis/server/index.ts');
  } catch { return false; }
});
assert.ok(pid, 'server process not found');
const rssKiB = () => Number(/^VmRSS:\s+(\d+)/m.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))?.[1]);
const initial = rssKiB();
const started = Date.now();
let checks = 0;
while (Date.now() - started < seconds * 1000) {
  const response = await fetch('http://127.0.0.1:7317/api/health', { signal: AbortSignal.timeout(7000) });
  const body = await response.json();
  assert.ok(response.ok && body.ok && body.herdr?.runtime === 'herdr-core' && body.auth?.required === true);
  checks++;
  await new Promise(resolve => setTimeout(resolve, 2000));
}
console.log(`PASS: ${Math.round((Date.now() - started) / 1000)}s readiness soak, ${checks} checks, server RSS ${initial} -> ${rssKiB()} KiB (short observation, not a leak/24h stability proof)`);
