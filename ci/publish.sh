#!/bin/sh
# Tag, push, and optionally sign an image that ci/build.sh, ci/test.sh, and
# ci/scan.sh already accepted. Works for GHCR and the Forgejo registry.
#
# Usage: sh ci/publish.sh LOCAL_IMAGE
# Required env:
#   LUCOA_IMAGE_NAME   registry/owner/name, lowercase (e.g. ghcr.io/me/lucoa)
#   REGISTRY_USER, REGISTRY_PASSWORD
#   GITHUB_SHA         commit to tag as sha-<commit>
# Optional env:
#   GITHUB_REF         refs/tags/vX.Y.Z adds X.Y.Z (and X.Y for stable releases)
#   LUCOA_TAG_LATEST   true | false | auto (default auto: stable release tags only)
#   COSIGN_PRIVATE_KEY, COSIGN_PASSWORD   sign and attest the SBOM when set
#   COSIGN_SIGN_ARGS   extra cosign arguments (for example --signing-config FILE)
set -eu
cd "$(dirname "$0")/.."
. ci/lib.sh
require_x86_64
detect_engine
ci_bin
ci_out
local_image=${1:?usage: sh ci/publish.sh LOCAL_IMAGE}
name=${LUCOA_IMAGE_NAME:?set LUCOA_IMAGE_NAME}
sha=${GITHUB_SHA:?set GITHUB_SHA}
: "${REGISTRY_USER:?set REGISTRY_USER}" "${REGISTRY_PASSWORD:?set REGISTRY_PASSWORD}"
case "$name" in *[A-Z]*) fail 'LUCOA_IMAGE_NAME must be lowercase' ;; esac
registry=${name%%/*}

version=$(ref_version "${GITHUB_REF:-}")
tags="sha-$sha"
if [ -n "$version" ]; then
    tags="$tags $version"
    case "$version" in
        *-*) stable=0 ;;
        *) stable=1; tags="$tags ${version%.*}" ;;
    esac
else
    stable=0
fi
case "${LUCOA_TAG_LATEST:-auto}" in
    true) tags="$tags latest" ;;
    false) ;;
    auto) [ "$stable" = 0 ] || tags="$tags latest" ;;
    *) fail 'LUCOA_TAG_LATEST must be true, false, or auto' ;;
esac

# Keep registry credentials in a throwaway config, never in the runner's home
# (host runners share it between jobs). Docker and Podman both honor these.
auth=$(mktemp -d)
trap 'rm -rf "$auth"' EXIT HUP INT TERM
DOCKER_CONFIG=$auth
REGISTRY_AUTH_FILE=$auth/config.json
export DOCKER_CONFIG REGISTRY_AUTH_FILE
printf '%s' "$REGISTRY_PASSWORD" | "$CONTAINER_ENGINE" login --username "$REGISTRY_USER" --password-stdin "$registry" >/dev/null
note "logged in to $registry"

for tag in $tags; do
    "$CONTAINER_ENGINE" tag "$local_image" "$name:$tag"
    if [ "$CONTAINER_ENGINE" = podman ]; then
        "$CONTAINER_ENGINE" push --digestfile "$auth/digest" "$name:$tag"
    else
        "$CONTAINER_ENGINE" push "$name:$tag"
    fi
    note "pushed $name:$tag"
done

# Resolve the pushed manifest digest so signatures bind to content, not a tag.
if [ "$CONTAINER_ENGINE" = podman ]; then
    digest=$(cat "$auth/digest")
else
    digest=$("$CONTAINER_ENGINE" image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$name:sha-$sha" \
        | grep "^$name@" | head -n 1 | sed 's/.*@//')
fi
case "$digest" in sha256:*) ;; *) fail 'could not determine the pushed image digest' ;; esac
ref="$name@$digest"
summary '### Published' '' "Digest: \`$ref\`" '' "Tags: \`$tags\`"

if [ -n "${COSIGN_PRIVATE_KEY:-}" ]; then
    command -v cosign >/dev/null || fail 'cosign not installed; run sh ci/install-tools.sh cosign'
    export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
    # Sigstore's default signing config records signatures in the public Rekor
    # transparency log. Override with COSIGN_SIGN_ARGS for a private setup.
    # shellcheck disable=SC2086
    cosign sign --yes --key env://COSIGN_PRIVATE_KEY ${COSIGN_SIGN_ARGS:-} "$ref"
    if [ -f "$LUCOA_CI_OUT/sbom.cdx.json" ]; then
        # shellcheck disable=SC2086
        cosign attest --yes --key env://COSIGN_PRIVATE_KEY ${COSIGN_SIGN_ARGS:-} \
            --type cyclonedx --predicate "$LUCOA_CI_OUT/sbom.cdx.json" "$ref"
        note 'attached signed CycloneDX SBOM attestation'
    fi
    summary '' 'Signed with cosign (verify with `cosign verify --key cosign.pub '"$ref"'`).'
else
    note 'COSIGN_PRIVATE_KEY not set; image is not signed'
    summary '' 'Not signed: COSIGN_PRIVATE_KEY secret is not configured.'
fi
printf '%s\n' "$ref"
