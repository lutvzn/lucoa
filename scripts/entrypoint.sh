#!/bin/sh
set -eu
fail() { printf 'lucoa: %s\n' "$1" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || fail 'refusing to run as root'
umask 077

# Command overrides (for example /bin/bash) do not require a web token.
if [ "${1:-}" = bun ] && [ "${2:-}" = /opt/lucoa/ovis/server/index.ts ]; then
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
fi

exec "$@"
