#!/bin/sh
# Builds are separate: CONTAINER_ENGINE=podman sh tests/smoke.sh localhost/lucoa:local
# Single-quoted programs below intentionally expand inside the container.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."
engine=${CONTAINER_ENGINE:-docker}
image=${1:-lucoa:local}
name="lucoa-smoke-$$"
home="${name}-home"
workspace="${name}-workspace"
tmp=$(mktemp -d)
cleanup() {
    "$engine" rm -f "$name" >/dev/null 2>&1 || true
    "$engine" volume rm "$home" "$workspace" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

"$engine" image inspect "$image" --format '{{json .Config.Healthcheck}}' | grep -q '/usr/local/lib/lucoa/healthcheck.mjs'
configured_user=$("$engine" image inspect "$image" --format '{{.Config.User}}')
case "$configured_user" in ''|root|0|0:*) echo 'FAIL: image default user is root/unset' >&2; exit 1 ;; esac
"$engine" run --rm --cap-drop=ALL --security-opt=no-new-privileges "$image" sh -eu -c '
    test "$(id -u)" = 1000
    test "$(node -p "process.versions.node.split(\".\")[0]")" = 26
    test -f /etc/debian_version
    for tool in bun hc herdr-core claude pi git rg bash python3 uv uvx dropbear dropbearkey; do command -v "$tool"; done
    bun --version; hc --version; claude --version; pi --version
    python3 --version; uv --version; uvx --version
    ! command -v sudo
    ! command -v doas
    ! command -v su
    test -z "$(find /bin /sbin /usr -type f -perm /6000 -print)"
    test -w /opt/lucoa; test -w "$HOME"; test -w /workspace
'
"$engine" run --rm -i --network=none --cap-drop=ALL --security-opt=no-new-privileges \
    "$image" python3 - < tests/python.py
if "$engine" run --rm "$image" >"$tmp/no-token.log" 2>&1; then
    echo 'FAIL: server started without a token' >&2; exit 1
fi
grep -q 'set a nonempty OVIS_TOKEN' "$tmp/no-token.log"
if "$engine" run --rm --user 0 "$image" /bin/true >"$tmp/root.log" 2>&1; then
    echo 'FAIL: root execution was accepted' >&2; exit 1
fi
grep -q 'refusing to run as root' "$tmp/root.log"

# Pass the test token by environment, not expanded command arguments or log output.
OVIS_TOKEN=$("$engine" run --rm "$image" node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')
export OVIS_TOKEN
"$engine" volume create "$home" >/dev/null
"$engine" volume create "$workspace" >/dev/null
start() {
    "$engine" run -d --name "$name" --init --cap-drop=ALL --security-opt=no-new-privileges \
        "$@" -v "$home:/home/node" -v "$workspace:/workspace" "$image" >/dev/null
}
ready() {
    i=0
    until "$engine" exec "$name" node /usr/local/lib/lucoa/healthcheck.mjs >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 45 ]; then
            echo 'FAIL: server did not become ready' >&2
            "$engine" logs "$name" >&2
            exit 1
        fi
        sleep 2
    done
}
start -e OVIS_TOKEN
ready
"$engine" cp tests/http.mjs "$name:/tmp/lucoa-http.mjs"
"$engine" exec "$name" bun /tmp/lucoa-http.mjs
if [ "${LUCOA_SOAK_SECONDS:-0}" != 0 ]; then
    export LUCOA_SOAK_SECONDS
    "$engine" cp tests/soak.mjs "$name:/tmp/lucoa-soak.mjs"
    "$engine" exec -e LUCOA_SOAK_SECONDS "$name" node /tmp/lucoa-soak.mjs
fi
"$engine" exec "$name" sh -eu -c '
    for dir in "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$OVIS_STATE_DIR"; do
        test -w "$dir"; test "$(stat -c %a "$dir")" = 700
    done
    printf home-persist > "$HOME/.lucoa-smoke"
    printf workspace-persist > /workspace/.lucoa-smoke
'
# Exercise file-based secrets on recreation without putting the token in argv.
"$engine" exec "$name" node -e 'require("fs").writeFileSync(process.env.HOME + "/.lucoa-test-token", process.env.OVIS_TOKEN, {mode: 0o600})'
"$engine" stop -t 20 "$name" >/dev/null
"$engine" rm "$name" >/dev/null
start -e OVIS_TOKEN_FILE=/home/node/.lucoa-test-token
ready
"$engine" cp tests/http.mjs "$name:/tmp/lucoa-http.mjs"
"$engine" exec -e OVIS_TOKEN "$name" bun /tmp/lucoa-http.mjs
"$engine" exec "$name" sh -eu -c '
    test "$(cat "$HOME/.lucoa-smoke")" = home-persist
    test "$(cat /workspace/.lucoa-smoke)" = workspace-persist
    test -x /opt/lucoa/bin/pi; test -x /opt/lucoa/bin/claude
'
"$engine" stop -t 20 "$name" >/dev/null
exit_code=$("$engine" inspect "$name" --format '{{.State.ExitCode}}')
[ "$exit_code" = 0 ] || { echo "FAIL: nonzero shutdown: $exit_code" >&2; exit 1; }
echo 'PASS: non-root tools, auth-required startup, hardened runtime, HTTP/WebSocket workflow, token file, persistent mounts, graceful shutdown'
echo 'NOT TESTED: real provider credentials, graphical browser UI, Traefik, LAN firewall rules, long soak, arm64'
