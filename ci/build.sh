#!/bin/sh
# Build the linux/amd64 image with Docker or Podman.
# Usage: sh ci/build.sh IMAGE_TAG
# Optional env: LUCOA_BUILD_FRESH=1 (pull base, no layer cache),
# LUCOA_EXTRA_DNF_PACKAGES, LUCOA_SOURCE_URL, LUCOA_VERSION, GITHUB_SHA.
set -eu
cd "$(dirname "$0")/.."
. ci/lib.sh
require_x86_64
detect_engine
image=${1:?usage: sh ci/build.sh IMAGE_TAG}
LUCOA_VERSION=${LUCOA_VERSION:-$(ref_version "${GITHUB_REF:-}")}

set -- --platform linux/amd64 \
    --label "org.opencontainers.image.title=lucoa" \
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ -z "${LUCOA_SOURCE_URL:-}" ] || set -- "$@" --label "org.opencontainers.image.source=$LUCOA_SOURCE_URL"
[ -z "${GITHUB_SHA:-}" ] || set -- "$@" --label "org.opencontainers.image.revision=$GITHUB_SHA"
[ -z "${LUCOA_VERSION:-}" ] || set -- "$@" --label "org.opencontainers.image.version=$LUCOA_VERSION"
[ -z "${LUCOA_EXTRA_DNF_PACKAGES:-}" ] || set -- "$@" --build-arg "EXTRA_DNF_PACKAGES=$LUCOA_EXTRA_DNF_PACKAGES"
[ "${LUCOA_BUILD_FRESH:-0}" != 1 ] || set -- "$@" --pull --no-cache
# Podman's default OCI format drops HEALTHCHECK; Docker format keeps it.
[ "$CONTAINER_ENGINE" != podman ] || set -- "$@" --format docker

note "building $image with $CONTAINER_ENGINE"
"$CONTAINER_ENGINE" build "$@" -t "$image" .
summary "Built \`$image\` with $CONTAINER_ENGINE (linux/amd64)."
