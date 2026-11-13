#!/bin/sh
set -eu
# shellcheck source=build/versions.env
. /tmp/lucoa-build/versions.env

case "$(uname -m)" in
  x86_64) ;;
  *) echo 'lucoa: fnm and Node are only pinned for x86_64 builds' >&2; exit 1 ;;
esac

export FNM_DIR=/opt/lucoa/fnm
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fetch() { curl --fail --show-error --silent --location --retry 3 --connect-timeout 20 "$1" -o "$2"; }
verify() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }

fetch "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/fnm-linux.zip" "$tmp/fnm.zip"
verify "$FNM_X64_SHA256" "$tmp/fnm.zip"
mkdir "$tmp/fnm"
unzip -q "$tmp/fnm.zip" -d "$tmp/fnm"
install -m 755 "$tmp/fnm/fnm" /opt/lucoa/bin/fnm
test "$(/opt/lucoa/bin/fnm --version)" = "fnm $FNM_VERSION"

# fnm 1.39 downloads Node without checking SHA-256 sums, so the pinned tarball is
# verified here and placed in fnm's own layout (node-versions/<v>/installation).
installation="$FNM_DIR/node-versions/v${NODE_VERSION}/installation"
fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" "$tmp/node.tar.xz"
verify "$NODE_X64_SHA256" "$tmp/node.tar.xz"
mkdir -p "$installation"
tar -xJf "$tmp/node.tar.xz" -C "$installation" --strip-components=1 --no-same-owner
/opt/lucoa/bin/fnm default "$NODE_VERSION"
test "$("$FNM_DIR/aliases/default/bin/node" --version)" = "v${NODE_VERSION}"
