#!/usr/bin/env bash
# Optional bounded readiness soak; no provider requests and no published ports.
set -euo pipefail

seconds=${LUCOA_SOAK_SECONDS:-}
if ! [[ $seconds =~ ^[0-9]+$ ]] || (( seconds < 1 || seconds > 86400 )); then
    echo 'FAIL: soak duration must be 1..86400 seconds' >&2
    exit 1
fi

server_pid=
for dir in /proc/[0-9]*; do
    args=$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null) || continue
    if [[ $args == "bun /opt/lucoa/ovis/server/index.ts"* ]]; then
        server_pid=${dir#/proc/}
        break
    fi
done
[[ -n $server_pid ]] || { echo 'FAIL: server process not found' >&2; exit 1; }

rss() { awk '/^VmRSS:/ { print $2 }' "/proc/$server_pid/status"; }
initial=$(rss)
start=$SECONDS
checks=0
while (( SECONDS - start < seconds )); do
    body=$(curl -fsS --max-time 7 http://127.0.0.1:7317/api/health)
    jq -e '.ok == true and .herdr.runtime == "herdr-core" and .auth.required == true' <<<"$body" >/dev/null \
        || { echo 'FAIL: readiness check failed' >&2; exit 1; }
    checks=$((checks + 1))
    sleep 2
done
echo "PASS: $((SECONDS - start))s readiness soak, $checks checks, server RSS $initial -> $(rss) KiB (short observation, not a leak/24h stability proof)"
