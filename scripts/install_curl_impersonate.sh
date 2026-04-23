#!/usr/bin/env bash
# Downloads curl-impersonate binaries into priv/bin/.
# Picks the right tarball for the current OS/arch.
set -euo pipefail

VERSION="${CURL_IMPERSONATE_VERSION:-v0.6.1}"
REPO="lwthiker/curl-impersonate"

os="$(uname -s)"
arch="$(uname -m)"

case "$os-$arch" in
  Darwin-x86_64) asset="curl-impersonate-${VERSION}.x86_64-macos.tar.gz" ;;
  Darwin-arm64)  asset="curl-impersonate-${VERSION}.x86_64-macos.tar.gz" ;;  # no native arm64 build; runs under Rosetta
  Linux-x86_64)  asset="curl-impersonate-${VERSION}.x86_64-linux-gnu.tar.gz" ;;
  Linux-aarch64) asset="curl-impersonate-${VERSION}.aarch64-linux-gnu.tar.gz" ;;
  *)
    echo "Unsupported platform: $os-$arch" >&2
    exit 1
    ;;
esac

dest_dir="$(cd "$(dirname "$0")/.." && pwd)/priv/bin"
mkdir -p "$dest_dir"

url="https://github.com/${REPO}/releases/download/${VERSION}/${asset}"
echo "Downloading $asset ..."
curl -fsSL "$url" | tar -xz -C "$dest_dir"

echo "Installed curl-impersonate binaries to $dest_dir"
ls "$dest_dir" | grep -E '^curl_(chrome|ff|safari|edge)' | head
