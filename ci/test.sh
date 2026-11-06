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
summary "Smoke and SSH suites passed for \`$image\`."
