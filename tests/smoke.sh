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
restored="${name}-restored"
tmp=$(mktemp -d)
cleanup() {
    "$engine" rm -f "$name" >/dev/null 2>&1 || true
    "$engine" volume rm "$home" "$workspace" "$restored" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

"$engine" image inspect "$image" --format '{{json .Config.Healthcheck}}' | grep -q '/usr/local/lib/lucoa/healthcheck.sh'
configured_user=$("$engine" image inspect "$image" --format '{{.Config.User}}')
case "$configured_user" in ''|root|0|0:*) echo 'FAIL: image default user is root/unset' >&2; exit 1 ;; esac
"$engine" run --rm --cap-drop=ALL --security-opt=no-new-privileges "$image" sh -eu -c '
    test "$(id -u)" = 5997
    test "$(node -p "process.versions.node.split(\".\")[0]")" = 26
    test "$(readlink -f "$(command -v node)")" = "$FNM_DIR/node-versions/v26.13.0/installation/bin/node"
    fnm --version
    grep -q "^ID=fedora$" /etc/os-release
    for tool in fnm bun hc herdr-core claude pi git rg bash python3 uv uvx dropbear dropbearkey jq less ssh ps podman podman-remote; do command -v "$tool"; done
    test "$(readlink -f "$(command -v podman)")" = /usr/bin/podman-remote
    podman --version
    test -x /usr/libexec/openssh/sftp-server
    printf "{\"ok\":true}" | jq -e .ok >/dev/null
    bun --version; hc --version; claude --version; pi --version
    python3 --version; uv --version; uvx --version
    for bin in sudo doas su sshd; do if command -v "$bin" >/dev/null; then echo "unexpected privilege or daemon tool: $bin" >&2; exit 1; fi; done
    test -z "$(find /bin /sbin /usr -type f -perm /6000 -print)"
    test -w /opt/lucoa; test -w "$HOME"; test -w /workspace
'
"$engine" run --rm -i --network=none --cap-drop=ALL --security-opt=no-new-privileges \
    "$image" python3 - < tests/python.py
if "$engine" run --rm "$image" >"$tmp/no-token.log" 2>&1; then
    echo 'FAIL: server started without a token' >&2; exit 1
fi
grep -q 'set a nonempty OVIS_TOKEN' "$tmp/no-token.log"
# Root is opt-in for command overrides only (with a warning); never for Ovis.
"$engine" run --rm --user 0 "$image" id -u >"$tmp/root-override.log" 2>&1
grep -qx 0 "$tmp/root-override.log"
grep -q 'warning: running a command override as root' "$tmp/root-override.log"
if "$engine" run --rm --user 0 "$image" >"$tmp/root.log" 2>&1; then
    echo 'FAIL: Ovis server started as root' >&2; exit 1
fi
grep -q 'refusing to run the Ovis server as root' "$tmp/root.log"

# Pass the test token by environment, not expanded command arguments or log output.
OVIS_TOKEN=$("$engine" run --rm "$image" sh -c 'od -An -N32 -tx1 /dev/urandom | tr -d " \n"')
export OVIS_TOKEN
"$engine" volume create "$home" >/dev/null
"$engine" volume create "$workspace" >/dev/null
start() {
    "$engine" run -d --name "$name" --init --cap-drop=ALL --security-opt=no-new-privileges \
        "$@" -v "$home:/home/lutvzn" -v "$workspace:/workspace" "$image" >/dev/null
}
ready() {
    i=0
    until "$engine" exec "$name" /usr/local/lib/lucoa/healthcheck.sh >/dev/null 2>&1; do
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
"$engine" cp tests/http.sh "$name:/tmp/lucoa-http.sh"
"$engine" exec -e OVIS_TOKEN "$name" bash /tmp/lucoa-http.sh
if [ "${LUCOA_SOAK_SECONDS:-0}" != 0 ]; then
    export LUCOA_SOAK_SECONDS
    "$engine" cp tests/soak.sh "$name:/tmp/lucoa-soak.sh"
    "$engine" exec -e LUCOA_SOAK_SECONDS "$name" bash /tmp/lucoa-soak.sh
fi
"$engine" exec "$name" sh -eu -c '
    for dir in "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$OVIS_STATE_DIR"; do
        test -w "$dir"; test "$(stat -c %a "$dir")" = 700
    done
    printf home-persist > "$HOME/.lucoa-smoke"
    printf workspace-persist > /workspace/.lucoa-smoke
'
# Exercise file-based secrets on recreation without putting the token in argv.
"$engine" exec -e OVIS_TOKEN "$name" sh -eu -c 'umask 077; printf "%s" "$OVIS_TOKEN" > "$HOME/.lucoa-test-token"'
"$engine" stop -t 20 "$name" >/dev/null
"$engine" rm "$name" >/dev/null
start -e OVIS_TOKEN_FILE=/home/lutvzn/.lucoa-test-token
ready
"$engine" cp tests/http.sh "$name:/tmp/lucoa-http.sh"
"$engine" exec -e OVIS_TOKEN "$name" bash /tmp/lucoa-http.sh
"$engine" exec "$name" sh -eu -c '
    test "$(cat "$HOME/.lucoa-smoke")" = home-persist
    test "$(cat /workspace/.lucoa-smoke)" = workspace-persist
    test -x /opt/lucoa/bin/pi; test -x /opt/lucoa/bin/claude
'
"$engine" stop -t 20 "$name" >/dev/null
exit_code=$("$engine" inspect "$name" --format '{{.State.ExitCode}}')
[ "$exit_code" = 0 ] || { echo "FAIL: nonzero shutdown: $exit_code" >&2; exit 1; }
# Documented backup/restore: stream a stopped volume through tar via stdout/stdin.
"$engine" run --rm --cap-drop=ALL --security-opt=no-new-privileges \
    -v "$home:/home/lutvzn:ro" "$image" tar -C /home/lutvzn -cf - . > "$tmp/home.tar"
tar -tf "$tmp/home.tar" | grep -qx './.lucoa-smoke'
"$engine" volume create "$restored" >/dev/null
"$engine" run --rm -i --cap-drop=ALL --security-opt=no-new-privileges \
    -v "$restored:/home/lutvzn" "$image" tar -C /home/lutvzn -xf - < "$tmp/home.tar"
"$engine" run --rm --cap-drop=ALL --security-opt=no-new-privileges \
    -v "$restored:/home/lutvzn:ro" "$image" sh -eu -c '
    test "$(cat "$HOME/.lucoa-smoke")" = home-persist
    test "$(stat -c %u:%a "$HOME/.lucoa-test-token")" = 5997:600
'
echo 'PASS: non-root tools, auth-required startup, hardened runtime, HTTP/WebSocket workflow, token file, persistent mounts, graceful shutdown, backup/restore, extra tools'
echo 'NOT TESTED: real provider credentials, graphical browser UI, Traefik, LAN firewall rules, long soak, arm64'
