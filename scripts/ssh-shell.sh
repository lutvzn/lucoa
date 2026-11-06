#!/bin/sh
# Dropbear intentionally does not inherit the service environment. Restore only
# the container's public tool paths and shared core state, never the Ovis token.
export HOME=/home/node
export PATH=/opt/lucoa/bin:/home/node/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_RUNTIME_DIR=/tmp/lucoa-runtime
export SHELL=/bin/bash
# Default mount point for an optional host Podman API socket (podman-remote).
export CONTAINER_HOST=unix:///run/podman/podman.sock
export USE_BUILTIN_RIPGREP=0 DISABLE_AUTOUPDATER=1 PI_SKIP_VERSION_CHECK=1
umask 077
cd /workspace || exit 1
exec /bin/bash "$@"
