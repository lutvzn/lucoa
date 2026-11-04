#!/bin/sh
set -eu
# shellcheck source=build/versions.env
. /tmp/lucoa-build/versions.env

case "$(uname -m)" in
  x86_64) bun_target=linux-x64-musl-baseline; bun_sha=$BUN_X64_SHA256; hc_arch=x86_64; hc_sha=$HC_X64_SHA256; uv_sha=$UV_X64_SHA256 ;;
  aarch64) bun_target=linux-aarch64-musl; bun_sha=$BUN_ARM64_SHA256; hc_arch=aarch64; hc_sha=$HC_ARM64_SHA256; uv_sha=$UV_ARM64_SHA256 ;;
  *) echo 'lucoa: unsupported build architecture' >&2; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fetch() { curl --fail --show-error --silent --location --retry 3 --connect-timeout 20 "$1" -o "$2"; }
verify() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
mkdir -p /opt/lucoa/bin /opt/lucoa/ovis

fetch "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-${bun_target}.zip" "$tmp/bun.zip"
verify "$bun_sha" "$tmp/bun.zip"
unzip -q "$tmp/bun.zip" -d "$tmp/bun"
cp "$tmp/bun/bun-${bun_target}/bun" /opt/lucoa/bin/bun
chmod 755 /opt/lucoa/bin/bun

fetch "https://releases.herdr.dev/core/${HC_VERSION}/herdr-core-linux-${hc_arch}.tar.gz" "$tmp/hc.tar.gz"
verify "$hc_sha" "$tmp/hc.tar.gz"
mkdir "$tmp/hc"
tar -xzf "$tmp/hc.tar.gz" -C "$tmp/hc"
cp "$tmp/hc/herdr-core" /opt/lucoa/bin/herdr-core
chmod 755 /opt/lucoa/bin/herdr-core
ln -s herdr-core /opt/lucoa/bin/hc

uv_target="${hc_arch}-unknown-linux-musl"
fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uv_target}.tar.gz" "$tmp/uv.tar.gz"
verify "$uv_sha" "$tmp/uv.tar.gz"
mkdir "$tmp/uv"
tar -xzf "$tmp/uv.tar.gz" -C "$tmp/uv"
cp "$tmp/uv/uv-${uv_target}/uv" "$tmp/uv/uv-${uv_target}/uvx" /opt/lucoa/bin/
chmod 755 /opt/lucoa/bin/uv /opt/lucoa/bin/uvx
uv --version
uvx --version

fetch "https://codeload.github.com/devswha/ovis/tar.gz/${OVIS_REVISION}" "$tmp/ovis.tar.gz"
verify "$OVIS_SHA256" "$tmp/ovis.tar.gz"
tar -xzf "$tmp/ovis.tar.gz" -C /opt/lucoa/ovis --strip-components=1
printf '%s\n' "$OVIS_REVISION" > /opt/lucoa/ovis/SOURCE_REVISION
bun --version
hc --version
