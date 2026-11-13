#!/bin/sh
# Bounded readiness probe. /api/health is intentionally public upstream and
# performs a backend ping. Do not put a token in arguments, output, or history.
set -eu
port=${PORT:-7317}
body=$(curl --fail --silent --show-error --max-time 7 "http://127.0.0.1:$port/api/health") || {
    echo 'lucoa: Ovis/backend readiness check failed' >&2
    exit 1
}
if ! printf '%s' "$body" | jq -e '.ok == true and (.herdr // false) != false and .auth.required == true' >/dev/null; then
    echo 'lucoa: Ovis/backend unavailable or authentication gate missing' >&2
    exit 1
fi
