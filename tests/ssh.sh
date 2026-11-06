#!/bin/sh
# Disposable SSH integration tests. Requires host OpenSSH client tools
# (ssh, ssh-keygen, sftp).
# Single-quoted programs intentionally expand in the container/SSH session.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."
engine=${CONTAINER_ENGINE:-docker}
image=${1:-lucoa:local}
name="lucoa-ssh-$$"
home="$name-home"
workspace="$name-workspace"
tmp=$(mktemp -d)
cleanup() {
    "$engine" rm -f "$name" >/dev/null 2>&1 || true
    "$engine" volume rm "$home" "$workspace" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
for tool in ssh ssh-keygen sftp; do command -v "$tool" >/dev/null; done
ssh-keygen -q -t ed25519 -N '' -f "$tmp/client"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/wrong"
"$engine" volume create "$home" >/dev/null
"$engine" volume create "$workspace" >/dev/null
# Provision only a disposable PUBLIC key into the disposable home volume.
"$engine" run --rm -i --cap-drop=ALL --security-opt=no-new-privileges \
    -v "$home:/home/node" "$image" sh -eu -c \
    'umask 077; mkdir -p "$HOME/.ssh"; cat > "$HOME/.ssh/authorized_keys"' < "$tmp/client.pub"
OVIS_TOKEN=$("$engine" run --rm "$image" node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')
export OVIS_TOKEN
start() {
    "$engine" run -d --name "$name" --init --cap-drop=ALL --security-opt=no-new-privileges \
        -e OVIS_TOKEN -p 127.0.0.1::2222 -v "$home:/home/node" \
        -v "$workspace:/workspace" "$@" "$image" >/dev/null
    port=$("$engine" port "$name" 2222/tcp | awk -F: '{print $NF}')
    i=0
    until "$engine" exec "$name" node /usr/local/lib/lucoa/healthcheck.mjs >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt 45 ] || { echo 'FAIL: readiness' >&2; exit 1; }
        sleep 2
    done
    # Trust the public host key obtained through the engine, not the network.
    "$engine" exec "$name" dropbearkey -y -f /home/node/.ssh/dropbear_ed25519_host_key 2>/dev/null \
        | awk -v host="[127.0.0.1]:$port" '/^ssh-ed25519 / {print host, $1, $2}' > "$tmp/known_hosts"
    test -s "$tmp/known_hosts"
}
remote() {
    ssh -F /dev/null -p "$port" -i "$tmp/client" -o IdentitiesOnly=yes \
        -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$tmp/known_hosts" "$@"
}
start
remote node@127.0.0.1 'set -eu; test "$(id -u)" = 1000; test "$PWD" = /workspace; test -z "${OVIS_TOKEN:-}"; command -v hc; command -v claude; command -v pi; hc --version; printf ssh-persist > /workspace/ssh-test' > "$tmp/output"
grep -q '/opt/lucoa/bin/hc' "$tmp/output"
if ! sleep 3 | remote -tt node@127.0.0.1 'test -t 0 && printf pty-ok' > "$tmp/pty"; then
    "$engine" logs "$name" >&2
    exit 1
fi
grep -q pty-ok "$tmp/pty"
# SFTP subsystem: starts in /workspace, uploads and downloads as UID 1000.
printf sftp-upload > "$tmp/upload"
printf '%s\n' pwd "put $tmp/upload sftp-upload" "get /workspace/ssh-test $tmp/download" > "$tmp/sftp-batch"
sftp -F /dev/null -P "$port" -i "$tmp/client" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$tmp/known_hosts" \
    -b "$tmp/sftp-batch" node@127.0.0.1 > "$tmp/sftp-out"
grep -q 'Remote working directory: /workspace' "$tmp/sftp-out"
[ "$(cat "$tmp/download")" = ssh-persist ]
remote node@127.0.0.1 'set -eu; test "$(cat /workspace/sftp-upload)" = sftp-upload; test "$(stat -c %u /workspace/sftp-upload)" = 1000'
remote node@127.0.0.1 'hc ls' > /dev/null
# Exercise the actual stdio RPC transport used by desktop clients.
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"terminal.list","params":{}}'; sleep 2; } \
    | remote node@127.0.0.1 'hc connect' > "$tmp/rpc"
grep -q '"result"' "$tmp/rpc"
grep -q '"terminals"' "$tmp/rpc"
# A core task keeps running after its SSH client disconnects.
remote node@127.0.0.1 "hc run --bg --name ssh-disconnect 'sleep 2; printf survived > /workspace/ssh-disconnect'" > /dev/null
sleep 3
remote node@127.0.0.1 'test "$(cat /workspace/ssh-disconnect)" = survived'
# Wrong key and root must not authenticate.
if remote nobody@127.0.0.1 true > /dev/null 2>&1; then
    echo 'FAIL: invalid user accepted' >&2; exit 1
fi
if ssh -F /dev/null -p "$port" -i "$tmp/wrong" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$tmp/known_hosts" node@127.0.0.1 true > /dev/null 2>&1; then
    echo 'FAIL: wrong key accepted' >&2; exit 1
fi
if remote root@127.0.0.1 true > /dev/null 2>&1; then
    echo 'FAIL: root accepted' >&2; exit 1
fi
if remote -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
    node@127.0.0.1 true > /dev/null 2>&1; then
    echo 'FAIL: non-public-key authentication accepted' >&2; exit 1
fi
fingerprint=$("$engine" exec "$name" sha256sum /home/node/.ssh/dropbear_ed25519_host_key)
"$engine" stop -t 20 "$name" >/dev/null
[ "$("$engine" inspect "$name" --format '{{.State.ExitCode}}')" = 0 ]
"$engine" rm "$name" >/dev/null
start
[ "$fingerprint" = "$("$engine" exec "$name" sha256sum /home/node/.ssh/dropbear_ed25519_host_key)" ]
remote node@127.0.0.1 'set -eu; test "$(cat /workspace/ssh-test)" = ssh-persist; hc ls' > /dev/null
# A failed SSH service must not leave a silently degraded Ovis-only container.
"$engine" exec "$name" sh -c 'kill -TERM "$(cat /tmp/lucoa-runtime/dropbear.pid)"'
[ "$("$engine" wait "$name")" = 1 ]
"$engine" rm "$name" >/dev/null
start -e LUCOA_SSH_ENABLED=0
"$engine" exec "$name" node --input-type=module -e '
    import net from "node:net";
    const socket = net.connect(2222, "127.0.0.1");
    socket.on("connect", () => process.exit(1));
    socket.on("error", error => process.exit(error.code === "ECONNREFUSED" ? 0 : 1));
'
# Exercise the runtime public-key import, with only a public key in the home.
"$engine" exec "$name" sh -eu -c 'mv "$HOME/.ssh/authorized_keys" "$HOME/import.pub"'
"$engine" stop -t 20 "$name" >/dev/null
"$engine" rm "$name" >/dev/null
start
if remote node@127.0.0.1 true > /dev/null 2>&1; then
    echo 'FAIL: empty authorized_keys accepted login' >&2; exit 1
fi
"$engine" stop -t 20 "$name" >/dev/null
"$engine" rm "$name" >/dev/null
start -e LUCOA_SSH_AUTHORIZED_KEYS_FILE=/home/node/import.pub
remote node@127.0.0.1 'test "$(id -u)" = 1000'
"$engine" stop -t 20 "$name" >/dev/null
"$engine" rm "$name" >/dev/null
# Raw public-key environment input supports multiple complete key lines.
LUCOA_SSH_AUTHORIZED_KEYS=$(printf '%s\n%s' "$(cat "$tmp/client.pub")" "$(cat "$tmp/wrong.pub")")
export LUCOA_SSH_AUTHORIZED_KEYS
start -e LUCOA_SSH_AUTHORIZED_KEYS
remote node@127.0.0.1 true
ssh -F /dev/null -p "$port" -i "$tmp/wrong" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$tmp/known_hosts" node@127.0.0.1 true
"$engine" stop -t 20 "$name" >/dev/null
"$engine" rm "$name" >/dev/null
# No raw input on recreation preserves the previously copied key set.
start
remote node@127.0.0.1 true
for mode in both blank private; do
    case "$mode" in
        both) input=$LUCOA_SSH_AUTHORIZED_KEYS; source=/unused ;;
        blank) input='   '; source='' ;;
        private) input='-----BEGIN OPENSSH PRIVATE KEY-----'; source='' ;;
    esac
    if "$engine" run --rm -e OVIS_TOKEN -e LUCOA_SSH_AUTHORIZED_KEYS="$input" \
        -e LUCOA_SSH_AUTHORIZED_KEYS_FILE="$source" "$image" > "$tmp/rejected" 2>&1; then
        echo "FAIL: invalid SSH key input accepted: $mode" >&2; exit 1
    fi
    case "$mode" in
        both) grep -q 'not both' "$tmp/rejected" ;;
        blank) grep -q 'must not be blank' "$tmp/rejected" ;;
        private) grep -q 'never private keys' "$tmp/rejected" ;;
    esac
done
unset LUCOA_SSH_AUTHORIZED_KEYS
echo 'PASS: SSH key login/file/env import, SFTP upload/download, multiline keys, conflicting/invalid input rejection, non-root tools/core, PTY, denied auth, empty keys, SSH disabled, persistence, graceful shutdown, failure propagation'
