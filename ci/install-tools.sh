#!/bin/sh
# Install checksum-pinned CI tools into .ci/bin (or $LUCOA_CI_BIN).
# Usage: sh ci/install-tools.sh [shellcheck] [hadolint] [trivy] [cosign]
# With no arguments, installs all of them.
set -eu
cd "$(dirname "$0")/.."
. ci/lib.sh
# shellcheck source=ci/tools.env
. ci/tools.env
require_x86_64
ci_bin
mkdir -p "$LUCOA_CI_BIN"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fetch() { curl --fail --show-error --silent --location --retry 3 --connect-timeout 20 "$1" -o "$2"; }
verify() { printf '%s  %s\n' "$1" "$2" | sha256sum -c --quiet - || fail "checksum mismatch: $2"; }

install_tool() {
    case "$1" in
        shellcheck)
            fetch "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.gz" "$tmp/sc.tar.gz"
            verify "$SHELLCHECK_SHA256" "$tmp/sc.tar.gz"
            tar -xzf "$tmp/sc.tar.gz" -C "$tmp"
            install -m 755 "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$LUCOA_CI_BIN/shellcheck"
            ;;
        hadolint)
            fetch "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-linux-x86_64" "$tmp/hadolint"
            verify "$HADOLINT_SHA256" "$tmp/hadolint"
            install -m 755 "$tmp/hadolint" "$LUCOA_CI_BIN/hadolint"
            ;;
        trivy)
            v=${TRIVY_VERSION#v}
            fetch "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/trivy_${v}_Linux-64bit.tar.gz" "$tmp/trivy.tar.gz"
            verify "$TRIVY_SHA256" "$tmp/trivy.tar.gz"
            mkdir "$tmp/trivy"
            tar -xzf "$tmp/trivy.tar.gz" -C "$tmp/trivy" trivy
            install -m 755 "$tmp/trivy/trivy" "$LUCOA_CI_BIN/trivy"
            ;;
        cosign)
            fetch "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" "$tmp/cosign"
            verify "$COSIGN_SHA256" "$tmp/cosign"
            install -m 755 "$tmp/cosign" "$LUCOA_CI_BIN/cosign"
            ;;
        *) fail "unknown tool: $1" ;;
    esac
    note "installed $1"
}

[ "$#" -gt 0 ] || set -- shellcheck hadolint trivy cosign
for tool in "$@"; do install_tool "$tool"; done
