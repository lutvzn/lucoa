#!/bin/sh
# Static checks: shell/JS syntax, ShellCheck, and hadolint.
# Run `sh ci/install-tools.sh shellcheck hadolint` first (CI does this).
set -eu
cd "$(dirname "$0")/.."
. ci/lib.sh
ci_bin

bash_scripts="scripts/services.sh tests/http.sh tests/soak.sh"
shell_scripts="build/install-upstream.sh build/install-fnm.sh scripts/entrypoint.sh scripts/ssh-shell.sh scripts/healthcheck.sh
tests/smoke.sh tests/ssh.sh tests/podman-remote.sh host/setup-builder.sh host/lucoa ci/lib.sh ci/install-tools.sh ci/lint.sh ci/build.sh
ci/test.sh ci/scan.sh ci/publish.sh"
js_scripts="ci/bump-versions.mjs"

for script in $shell_scripts; do sh -n "$script"; done
for script in $js_scripts; do node --check "$script"; done
for script in $bash_scripts; do bash -n "$script"; done
python3 -I -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' tests/python.py
note 'syntax checks passed'

command -v shellcheck >/dev/null || fail 'shellcheck not installed; run sh ci/install-tools.sh shellcheck'
# -x follows `.` includes; -P resolves them relative to the repository root.
# shellcheck disable=SC2086
shellcheck -x -P SCRIPTDIR:. $shell_scripts $bash_scripts
note 'shellcheck passed'

command -v hadolint >/dev/null || fail 'hadolint not installed; run sh ci/install-tools.sh hadolint'
hadolint --config .hadolint.yaml Dockerfile
note 'hadolint passed'
