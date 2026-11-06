#!/bin/sh
# Disposable podman-remote integration test (rootless Podman hosts only).
# Starts a temporary Podman API service on a private socket, mounts it into a
# throwaway lucoa container, and builds/runs/removes an image through it.
# Usage: sh tests/podman-remote.sh IMAGE
# Single-quoted programs below intentionally expand inside the container.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."
image=${1:-localhost/lucoa:local}
command -v podman >/dev/null || { echo 'SKIP: host podman not installed' >&2; exit 0; }
[ "$(id -u)" != 0 ] || { echo 'FAIL: run as an unprivileged host user (rootless Podman)' >&2; exit 1; }
tmp=$(mktemp -d)
built="localhost/lucoa-remote-test-$$"
service_pid=
cleanup() {
    [ -z "$service_pid" ] || kill "$service_pid" 2>/dev/null || true
    podman image rm -f "$built" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

# --time=0 keeps the temporary service up until cleanup kills it.
podman system service --time=0 "unix://$tmp/podman.sock" &
service_pid=$!
i=0
until [ -S "$tmp/podman.sock" ]; do
    i=$((i + 1)); [ "$i" -lt 50 ] || { echo 'FAIL: podman API socket did not appear' >&2; exit 1; }
    sleep 0.2
done

# keep-id maps the host user (socket owner) to the container's node user.
# label=disable lets SELinux hosts connect to the mounted socket.
podman run --rm --cap-drop=ALL --security-opt=no-new-privileges \
    --userns=keep-id:uid=1000,gid=1000 --security-opt label=disable \
    -v "$tmp/podman.sock:/run/podman/podman.sock" \
    -e LUCOA_TEST_BASE="$image" -e LUCOA_TEST_TAG="$built" \
    "$image" sh -eu -c '
    test "$(id -u)" = 1000
    test "$(readlink -f "$(command -v podman)")" = /usr/bin/podman-remote
    podman --version
    podman info --format "{{.Host.Security.Rootless}}" | grep -qx true
    ctx=$(mktemp -d)
    printf "FROM %s\nRUN test \"\$(id -u)\" = 1000 && echo built-in-lucoa > /tmp/marker\n" "$LUCOA_TEST_BASE" > "$ctx/Containerfile"
    podman build --quiet -t "$LUCOA_TEST_TAG" "$ctx" >/dev/null
    test "$(podman run --rm "$LUCOA_TEST_TAG" cat /tmp/marker)" = built-in-lucoa
    podman image rm "$LUCOA_TEST_TAG" >/dev/null
'
if podman image exists "$built"; then
    echo 'FAIL: image removal through podman-remote did not reach the host' >&2; exit 1
fi
echo 'PASS: podman-remote client, rootless host API over mounted socket, build/run/remove as UID 1000'
