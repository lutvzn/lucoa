#!/bin/bash
# Supervise the two foreground services (Dropbear SSH and the container command).
# An unexpected exit of either stops the other and fails the container so the
# engine or systemd can restart it. Engine init reaps descendants.
set -u

log() { printf 'lucoa: %s\n' "$*" >&2; }
(( $# > 0 )) || { log 'services: no command given'; exit 2; }

declare -A pids=()   # service name -> pid
stopping=0
exit_code=0
killer=

request_stop() {
    local code=$1 name
    (( stopping == 0 )) || return 0
    stopping=1
    exit_code=$code
    for name in "${!pids[@]}"; do kill -TERM "${pids[$name]}" 2>/dev/null || true; done
    # Force-kill anything still running after 15 seconds.
    ( sleep 15; for name in "${!pids[@]}"; do kill -KILL "${pids[$name]}" 2>/dev/null || true; done ) &
    killer=$!
}

start() {
    local name=$1
    shift
    "$@" &
    pids[$name]=$!
}

trap 'request_stop 0' TERM INT

# Disable passwords, root login, and forwarding. hc uses SSH command/stdio.
# Do not pass -e: authenticated shells must not inherit service secrets.
start ssh dropbear -F -E -m -s -w -j -k \
    -p 0.0.0.0:2222 -P "$XDG_RUNTIME_DIR/dropbear.pid" \
    -r "$HOME/.ssh/dropbear_ed25519_host_key"
start service "$@"

while (( ${#pids[@]} > 0 )); do
    done_pid=
    if wait -n -p done_pid; then rc=0; else rc=$?; fi
    # Interrupted by a signal trap: no child was reaped.
    [[ -n ${done_pid:-} ]] || continue
    for name in "${!pids[@]}"; do
        if [[ ${pids[$name]} == "${done_pid:-}" ]]; then
            unset "pids[$name]"
            if (( stopping == 0 )); then
                log "$name exited unexpectedly (status $rc); stopping container"
                request_stop 1
            fi
        fi
    done
done

[[ -n $killer ]] && kill "$killer" 2>/dev/null || true
exit "$exit_code"
