#!/bin/sh
# Run both disposable credential-free suites against a built image.
# Usage: sh ci/test.sh IMAGE_TAG
# The SSH suite needs host ssh, ssh-keygen, and sftp clients.
set -eu
cd "$(dirname "$0")/.."
. ci/lib.sh
require_x86_64
detect_engine
image=${1:?usage: sh ci/test.sh IMAGE_TAG}
sh tests/smoke.sh "$image"
sh tests/ssh.sh "$image"
# podman-remote needs a libpod API, so this suite runs only on Podman hosts.
if [ "$CONTAINER_ENGINE" = podman ]; then
    sh tests/podman-remote.sh "$image"
    summary "Smoke, SSH, and podman-remote suites passed for \`$image\`."
else
    note 'skipping tests/podman-remote.sh (requires CONTAINER_ENGINE=podman)'
    summary "Smoke and SSH suites passed for \`$image\` (podman-remote suite skipped: not a Podman runner)."
fi
