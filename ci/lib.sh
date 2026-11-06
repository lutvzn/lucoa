#!/bin/sh
# Shared helpers for the CI scripts. Sourced, not executed.
# Works on GitHub Actions and Forgejo Actions (host runner), or locally.

fail() { printf 'lucoa-ci: %s\n' "$1" >&2; exit 1; }
note() { printf 'lucoa-ci: %s\n' "$1" >&2; }

# Only linux/amd64 is built and tested. Refuse elsewhere rather than
# producing an untested image.
require_x86_64() {
    [ "$(uname -s)" = Linux ] || fail 'CI scripts require Linux'
    [ "$(uname -m)" = x86_64 ] || fail "only x86_64 runners are supported (got $(uname -m))"
}

# CONTAINER_ENGINE wins; otherwise prefer docker, then podman.
detect_engine() {
    if [ -n "${CONTAINER_ENGINE:-}" ]; then
        command -v "$CONTAINER_ENGINE" >/dev/null || fail "CONTAINER_ENGINE=$CONTAINER_ENGINE not found"
    elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        CONTAINER_ENGINE=docker
    elif command -v podman >/dev/null; then
        CONTAINER_ENGINE=podman
    else
        fail 'no usable container engine (docker or podman) on this runner'
    fi
    export CONTAINER_ENGINE
}

# Pinned CI tools are installed here by ci/install-tools.sh.
ci_bin() {
    LUCOA_CI_BIN=${LUCOA_CI_BIN:-$PWD/.ci/bin}
    PATH="$LUCOA_CI_BIN:$PATH"
    export LUCOA_CI_BIN PATH
}

ci_out() {
    LUCOA_CI_OUT=${LUCOA_CI_OUT:-$PWD/.ci/out}
    mkdir -p "$LUCOA_CI_OUT"
    export LUCOA_CI_OUT
}

# Print the release version for a vX.Y.Z[-pre] tag ref, or nothing.
ref_version() {
    case "${1:-}" in
        refs/tags/v[0-9]*)
            v=${1#refs/tags/v}
            # Only plain SemVer characters may become image tags.
            if printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
                printf '%s\n' "$v"
            fi
            ;;
    esac
}

# Append Markdown to the job summary when the platform provides one.
summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
    fi
}
