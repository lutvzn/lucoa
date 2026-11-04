// /api/health is intentionally public upstream and performs a backend ping.
// Do not put a token in probe arguments, output, or health-check history.
try {
  const port = Number(process.env.PORT ?? 7317);
  const response = await fetch(`http://127.0.0.1:${port}/api/health`, {
    signal: AbortSignal.timeout(7000),
  });
  const body = await response.json();
  if (!response.ok || body.ok !== true || !body.herdr || body.auth?.required !== true) {
    throw new Error('Ovis/backend unavailable or authentication gate missing');
  }
} catch {
  console.error('lucoa: Ovis/backend readiness check failed');
  process.exitCode = 1;
}
