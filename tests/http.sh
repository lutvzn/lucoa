#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters below intentionally use $variables for --arg values
# Credential-free authenticated API and WebSocket terminal checks, in bash.
# Runs inside the test container: OVIS_TOKEN=... bash /tmp/lucoa-http.sh
# The WebSocket client is pure bash over /dev/tcp: the image's curl has no
# WebSocket support and no websocat package is available. jq parses JSON.
set -euo pipefail
export LC_ALL=C

HOST=127.0.0.1
PORT=7317
ORIGIN="http://$HOST:$PORT"
BASE="$ORIGIN"
: "${OVIS_TOKEN:?OVIS_TOKEN is required}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

WS_FD=
WS_FRAG=
WS_FRAG_OP=0
WS_MESSAGES=()

# Send one masked client frame. Payload is ASCII-only here (command text, JSON).
ws_send_frame() {  # opcode payload
    local op=$1 payload=$2 len=${#2} i n c hdr mask_hex body='' mask
    (( len < 65536 )) || fail "WebSocket frame too large"
    read -ra mask <<<"$(od -An -N4 -tu1 /dev/urandom)"
    if (( len < 126 )); then
        printf -v hdr '\\x%02x\\x%02x' $((0x80 | op)) $((0x80 | len))
    else
        printf -v hdr '\\x%02x\\x%02x\\x%02x\\x%02x' $((0x80 | op)) 254 $((len >> 8)) $((len & 255))
    fi
    printf -v mask_hex '\\x%02x\\x%02x\\x%02x\\x%02x' "${mask[@]}"
    for (( i = 0; i < len; i++ )); do
        printf -v n '%d' "'${payload:i:1}"
        printf -v c '\\x%02x' $(( n ^ mask[i % 4] ))
        body+=$c
    done
    # The pieces are only \xNN escapes, so interpreting them as a format is safe.
    # shellcheck disable=SC2059 # the pieces are only \xNN escapes
    printf "${hdr}${mask_hex}${body}" >&"$WS_FD"
}

ws_send_json() {  # ws_send_json jq-args... filter
    ws_send_frame 1 "$(jq -cn "$@")"
}

ws_close() {
    [[ -n $WS_FD ]] || return 0
    ws_send_frame 8 "" 2>/dev/null || true
    eval "exec ${WS_FD}>&-" 2>/dev/null || true
    WS_FD=
}

ws_open() {  # ws_open header... ; returns 1 when the upgrade is refused
    local key status line
    exec {WS_FD}<>"/dev/tcp/$HOST/$PORT" || return 1
    key=$(head -c 16 /dev/urandom | base64 | tr -d '\n')
    {
        printf 'GET /ws HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\n' "$HOST" "$PORT"
        printf 'Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n' "$key"
        for line in "$@"; do printf '%s\r\n' "$line"; done
        printf '\r\n'
    } >&"$WS_FD"
    IFS= read -r -t 5 -u "$WS_FD" status || { ws_close; return 1; }
    status=${status%$'\r'}
    while IFS= read -r -t 5 -u "$WS_FD" line && [[ -n ${line%$'\r'} ]]; do :; done
    if [[ $status != "HTTP/1.1 101"* ]]; then
        ws_close
        return 1
    fi
    WS_MESSAGES=()
    WS_FRAG=
    WS_CLOSED=0
}

# Raw socket bytes. bash `read` drops NUL bytes, and frame lengths contain
# zeros, so header and payload bytes come from dd instead. Returns the decimal
# byte values, space separated.
ws_raw_bytes() {  # count
    timeout 10 dd bs=1 count="$1" iflag=fullblock status=none <&"$WS_FD" | od -An -v -tu1
}

# Read one server frame; returns 1 when nothing arrives within the timeout.
ws_read_frame() {  # timeout-seconds
    local timeout=$1 first b1 b2 op fin len i ext payload
    # The first byte is never NUL (FIN bit or opcode is set), so bash read is safe here
    # and consumes exactly one byte, leaving the rest for dd.
    IFS= read -r -N 1 -t "$timeout" -u "$WS_FD" first || return 1
    b1=$(printf '%d' "'$first")
    b2=$(ws_raw_bytes 1) || return 1
    b2=${b2//[[:space:]]/}
    (( (b2 & 128) == 0 )) || fail "server frame is masked"
    fin=$(( b1 & 128 ))
    op=$(( b1 & 15 ))
    len=$(( b2 & 127 ))
    if (( len == 126 )); then
        read -ra ext <<<"$(ws_raw_bytes 2)" || return 1
        len=$(( ext[0] * 256 + ext[1] ))
    elif (( len == 127 )); then
        read -ra ext <<<"$(ws_raw_bytes 8)" || return 1
        len=0
        for (( i = 0; i < 8; i++ )); do
            len=$(( len * 256 + ext[i] ))
        done
    fi
    payload=
    if (( len > 0 )); then
        payload=$(timeout 10 dd bs=65536 count="$len" iflag=fullblock,count_bytes status=none <&"$WS_FD") || return 1
    fi
    case $op in
        0|1|2)
            if (( op != 0 )); then WS_FRAG_OP=$op; WS_FRAG=; fi
            WS_FRAG+=$payload
            if (( fin != 0 )); then
                if (( WS_FRAG_OP == 1 )); then WS_MESSAGES+=("$WS_FRAG"); fi
                WS_FRAG=
            fi
            ;;
        8) WS_CLOSED=1 ;;
        9) ws_send_frame 10 "$payload" ;;
    esac
    return 0
}

# True when the collected messages satisfy the jq arguments (last one is the filter).
ws_has() {
    printf '%s\n' "${WS_MESSAGES[@]}" | jq -s -e "$@" >/dev/null 2>&1
}

ws_wait() {  # ws_wait description timeout jq-args...
    local what=$1 timeout=$2 deadline
    shift 2
    deadline=$(( SECONDS + timeout ))
    while (( SECONDS < deadline )); do
        if ws_has "$@"; then return 0; fi
        while ws_read_frame 0.2; do :; done
        [[ ${WS_CLOSED:-0} == 0 ]] || fail "server closed the WebSocket while waiting for: $what"
    done
    fail "timed out: $what"
}

# HTTP helper: prints the status code and stores the body in OUT.
http_status() {  # method path out-file [curl args...]
    local method=$1 path=$2 out=$3
    shift 3
    curl -sS -o "$out" -w '%{http_code}' -X "$method" "$@" "$BASE$path"
}

expect_status() {  # expected-code method path [curl args...]
    local want=$1 method=$2 path=$3 status
    shift 3
    status=$(http_status "$method" "$path" /dev/null "$@")
    [[ $status == "$want" ]] || fail "unexpected HTTP status for $path: $status (wanted $want)"
}

tmp=$(mktemp -d)
trap 'ws_close; rm -rf "$tmp"' EXIT

# Static assets and the public surface.
[[ $(http_status GET / "$tmp/page") == 200 ]] || fail "index not served"
grep -qi '<html' "$tmp/page" || fail "index is not HTML"
[[ $(http_status GET /api/health "$tmp/health") == 200 ]] || fail "health not served"
jq -e '.ok == true and .auth.required == true and .herdr.runtime == "herdr-core"' "$tmp/health" >/dev/null \
    || fail "health body does not show herdr-core with auth required"

# Anonymous access must be rejected everywhere.
for path in /api/session /api/agent-catalog; do
    expect_status 401 GET "$path"
done
if ws_open "Origin: $ORIGIN"; then
    ws_close
    fail "anonymous WebSocket accepted"
fi

# Spoofed proxy identity headers must not bypass authentication.
expect_status 401 GET /api/session \
    -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
    -H 'Tailscale-User-Login: owner@example.invalid' -H 'X-Portal-User: owner'

json_headers=(-H 'Content-Type: application/json' -H "Origin: $ORIGIN")
expect_status 401 POST /api/auth "${json_headers[@]}" \
    --data "$(jq -cn '{token: "deliberately-wrong-smoke-token"}')"

login_status=$(curl -sS -o /dev/null -D "$tmp/login.headers" -w '%{http_code}' -X POST \
    "${json_headers[@]}" --data "$(jq -cn --arg t "$OVIS_TOKEN" '{token: $t}')" "$BASE/api/auth")
[[ $login_status == 204 ]] || fail "login did not return 204: $login_status"
cookie=$(tr -d '\r' < "$tmp/login.headers" | awk 'tolower($1) == "set-cookie:" {
    value = $2; sub(/;.*/, "", value); joined = joined sep value; sep = "; " }
    END { printf "%s", joined }')
[[ -n $cookie ]] || fail "login returned no session cookie"

auth=(-H "Cookie: $cookie" -H "Origin: $ORIGIN" -H 'Content-Type: application/json')
curl -fsS "${auth[@]}" "$BASE/api/health" > "$tmp/auth-health"
jq -e '.security.token_configured == true and .herdr.runtime == "herdr-core"' "$tmp/auth-health" >/dev/null \
    || fail "authenticated health is wrong"
curl -fsS "${auth[@]}" "$BASE/api/updates" > "$tmp/updates"
jq -e '.managed == false' "$tmp/updates" >/dev/null || fail "image should not use the managed in-app updater"

# Check actual installed detection, not just presence in the static catalog.
curl -fsS "${auth[@]}" "$BASE/api/agent-catalog" > "$tmp/catalog"
for agent_id in claude pi; do
    jq -e --arg id "$agent_id" '.agents[] | select(.id == $id) | .state
        | .installed == true and .on_path == true and .version_error == null' "$tmp/catalog" >/dev/null \
        || fail "agent not installed, not on PATH, or version probe failed: $agent_id"
done

curl -fsS "${auth[@]}" -X POST --data "$(jq -cn '{cwd: "/workspace", label: "lucoa smoke"}')" \
    "$BASE/api/workspace/create" > "$tmp/created"
pane=$(jq -r '.pane_id // empty' "$tmp/created")
workspace=$(jq -r '.workspace_id // empty' "$tmp/created")
[[ -n $pane && -n $workspace ]] || fail "workspace creation returned no pane or workspace id"

# Live terminal I/O, then reconnect after the browser disconnects.
ws_open "Cookie: $cookie" "Origin: $ORIGIN" || fail "authenticated WebSocket failed"
ws_wait "WebSocket snapshot" 15 'any(.[]; .type == "snapshot")'
ws_send_json --arg p "$pane" '{type: "attach", pane_id: $p, cols: 100, rows: 30}'
ws_wait "terminal readiness" 15 'any(.[]; .type == "input-ready" and .ready != false)'
input=$'printf \'%s%s\\n\' LUCOA_ WS_OK; sleep 3; printf \'%s%s\\n\' LUCOA_ RECONNECT_OK\r'
ws_send_json --arg p "$pane" --arg t "$input" '{type: "input", pane_id: $p, text: $t}'
ws_wait "live terminal output" 15 --arg p "$pane" --arg m LUCOA_WS_OK \
    '[.[] | select(.type == "pty-data" and .pane_id == $p) | .data] | join("") | contains($m)'
ws_close

sleep 4
ws_open "Cookie: $cookie" "Origin: $ORIGIN" || fail "WebSocket reconnect failed"
ws_wait "WebSocket snapshot after reconnect" 15 'any(.[]; .type == "snapshot")'
ws_has --arg p "$pane" 'any(.[]; tostring | contains($p))' || fail "reconnect snapshot does not mention the pane"
ws_send_json --arg p "$pane" '{type: "attach", pane_id: $p, cols: 100, rows: 30}'
ws_wait "task output after disconnected browser" 15 --arg p "$pane" --arg m LUCOA_RECONNECT_OK \
    '[.[] | select(.type == "pty-data" and .pane_id == $p) | .data] | join("") | contains($m)'
ws_close

curl -fsS "${auth[@]}" -X POST --data "$(jq -cn --arg w "$workspace" '{workspace_id: $w}')" \
    "$BASE/api/workspace/close" >/dev/null
echo 'PASS: assets, backend health, API/WebSocket auth, proxy-header rejection, agent detection, login, workspace creation, live terminal I/O and reconnect'
