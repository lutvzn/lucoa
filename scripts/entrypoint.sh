#!/bin/sh
set -eu
fail() { printf 'lucoa: %s\n' "$1" >&2; exit 1; }
umask 077

# Command overrides (for example /bin/bash) do not require a web token. Root is
# allowed for explicit overrides (--user 0 maintenance shells), with a warning.
# The default Ovis + SSH workload always runs unprivileged.
if [ "${1:-}" = bun ] && [ "${2:-}" = /opt/lucoa/ovis/server/index.ts ]; then
    [ "$(id -u)" -ne 0 ] || fail 'refusing to run the Ovis server as root; use the default node user'
    [ "${OVIS_RUNTIME:-}" = herdr-core ] || fail 'OVIS_RUNTIME must be herdr-core'
    if [ -n "${OVIS_TOKEN_FILE:-}" ]; then
        [ -z "${OVIS_TOKEN:-}" ] || fail 'set OVIS_TOKEN or OVIS_TOKEN_FILE, not both'
        [ -r "$OVIS_TOKEN_FILE" ] || fail 'OVIS_TOKEN_FILE is not readable by the runtime user'
        OVIS_TOKEN=$(cat "$OVIS_TOKEN_FILE")
        export OVIS_TOKEN
    fi
    [ -n "${OVIS_TOKEN:-}" ] || fail 'set a nonempty OVIS_TOKEN or OVIS_TOKEN_FILE before starting Ovis'
    # Avoid accepting an accidental blank/whitespace-only secret.
    case "$OVIS_TOKEN" in *[![:space:]]*) ;; *) fail 'OVIS_TOKEN must not be blank' ;; esac
    for dir in "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$OVIS_STATE_DIR"; do
        mkdir -p "$dir"
        [ "$(stat -c %u "$dir")" = "$(id -u)" ] || fail "directory is not owned by the runtime user: $dir"
        chmod 700 "$dir"
        [ -w "$dir" ] || fail "directory is not writable: $dir"
    done
    [ -w /workspace ] || fail '/workspace is not writable; fix mount ownership on the host'
    case "${LUCOA_SSH_ENABLED:-1}" in
        0) ;;
        1)
            ssh_dir="$HOME/.ssh"
            mkdir -p "$ssh_dir"
            [ ! -L "$ssh_dir" ] || fail '.ssh must not be a symlink'
            [ "$(stat -c %u "$ssh_dir")" = "$(id -u)" ] || fail '.ssh must be owned by the runtime user'
            chmod 700 "$ssh_dir"
            for file in authorized_keys dropbear_ed25519_host_key; do
                [ ! -L "$ssh_dir/$file" ] || fail "SSH file must not be a symlink: $file"
            done
            [ -z "${LUCOA_SSH_AUTHORIZED_KEYS:-}" ] || [ -z "${LUCOA_SSH_AUTHORIZED_KEYS_FILE:-}" ] \
                || fail 'set LUCOA_SSH_AUTHORIZED_KEYS or LUCOA_SSH_AUTHORIZED_KEYS_FILE, not both'
            if [ -n "${LUCOA_SSH_AUTHORIZED_KEYS:-}" ]; then
                case "$LUCOA_SSH_AUTHORIZED_KEYS" in
                    *'PRIVATE KEY'*) fail 'supply SSH public keys only, never private keys' ;;
                    *[![:space:]]*) ;;
                    *) fail 'LUCOA_SSH_AUTHORIZED_KEYS must not be blank' ;;
                esac
                printf '%s\n' "$LUCOA_SSH_AUTHORIZED_KEYS" > "$ssh_dir/authorized_keys"
            elif [ -n "${LUCOA_SSH_AUTHORIZED_KEYS_FILE:-}" ]; then
                [ -r "$LUCOA_SSH_AUTHORIZED_KEYS_FILE" ] || fail 'SSH public-key source is not readable'
                # Copy only public keys from a separate runtime mount, not secrets in image layers.
                cp "$LUCOA_SSH_AUTHORIZED_KEYS_FILE" "$ssh_dir/authorized_keys"
            fi
            # Provisioning input is not needed by either foreground service.
            unset LUCOA_SSH_AUTHORIZED_KEYS
            if [ ! -f "$ssh_dir/authorized_keys" ]; then
                : > "$ssh_dir/authorized_keys"
            fi
            chmod 600 "$ssh_dir/authorized_keys"
            if [ ! -f "$ssh_dir/dropbear_ed25519_host_key" ]; then
                dropbearkey -t ed25519 -f "$ssh_dir/dropbear_ed25519_host_key" >/dev/null
            fi
            chmod 600 "$ssh_dir/dropbear_ed25519_host_key"
            exec node /usr/local/lib/lucoa/services.mjs "$@"
            ;;
        *) fail 'LUCOA_SSH_ENABLED must be 0 or 1' ;;
    esac
fi

if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' 'lucoa: warning: running a command override as root; prefer the default node user' >&2
fi
exec "$@"
