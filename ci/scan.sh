#!/bin/sh
# Vulnerability scan and CycloneDX SBOM for a built image, using Trivy on an
# exported archive so it works the same with Docker and Podman.
# Usage: sh ci/scan.sh IMAGE_TAG
# Env: LUCOA_SCAN_FAIL_SEVERITY (default CRITICAL; "none" never fails),
#      LUCOA_SCAN_REPORT_SEVERITY (default HIGH,CRITICAL).
# Outputs: $LUCOA_CI_OUT/sbom.cdx.json and $LUCOA_CI_OUT/vulnerabilities.txt
set -eu
cd "$(dirname "$0")/.."
. ci/lib.sh
require_x86_64
detect_engine
ci_bin
ci_out
image=${1:?usage: sh ci/scan.sh IMAGE_TAG}
command -v trivy >/dev/null || fail 'trivy not installed; run sh ci/install-tools.sh trivy'
fail_severity=${LUCOA_SCAN_FAIL_SEVERITY:-CRITICAL}
report_severity=${LUCOA_SCAN_REPORT_SEVERITY:-HIGH,CRITICAL}
archive="$LUCOA_CI_OUT/image.tar"
trap 'rm -f "$archive"' EXIT HUP INT TERM

"$CONTAINER_ENGINE" save -o "$archive" "$image"
# Secret scanning is skipped: the image is built from an allowlisted context
# and the tests already check that no credentials are required at build time.
set -- --input "$archive" --scanners vuln --quiet
trivy image "$@" --format cyclonedx --output "$LUCOA_CI_OUT/sbom.cdx.json"
trivy image "$@" --severity "$report_severity" --ignore-unfixed \
    --format table --output "$LUCOA_CI_OUT/vulnerabilities.txt"
cat "$LUCOA_CI_OUT/vulnerabilities.txt"
summary '### Vulnerability scan (fixable only)' '```' "$(cat "$LUCOA_CI_OUT/vulnerabilities.txt")" '```'

if [ "$fail_severity" != none ]; then
    if ! trivy image "$@" --severity "$fail_severity" --ignore-unfixed --exit-code 1 \
        --format table --output /dev/null; then
        fail "fixable $fail_severity vulnerabilities found; rebuild (LUCOA_BUILD_FRESH=1) or bump pins"
    fi
fi
note "scan passed; SBOM at $LUCOA_CI_OUT/sbom.cdx.json"
