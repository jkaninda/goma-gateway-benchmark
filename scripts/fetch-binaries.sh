#!/usr/bin/env bash
# Put every binary the harness needs into bin/, for running bench.sh directly on
# a Linux host. (scripts/docker-run.sh does not need this: the runner image
# carries its own copies, at the versions pinned in docker/Dockerfile.)
#
#   ./scripts/fetch-binaries.sh
#   GOMA_VERSION=v1.2.1 TRAEFIK_VERSION=v3.7.19 ./scripts/fetch-binaries.sh
#   FORCE=1 ./scripts/fetch-binaries.sh            replace binaries already there
#
# Goma, Traefik and fortio come from their GitHub releases for this machine's
# architecture. nginx and HAProxy are not fetched: install them from the
# projects' own package repositories (nginx.org, haproxy.debian.net / PPA), not
# the distribution's, or the versions will not match the published results.
# benchtool is built from tools/benchtool with the Go toolchain.
#
# Keep the defaults in step with docker/Dockerfile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN_DIR:-$ROOT/bin}"
mkdir -p "$BIN"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GOMA_VERSION="${GOMA_VERSION:-v1.2.1}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.7.19}"
FORTIO_VERSION="${FORTIO_VERSION:-v1.77.0}"
FORCE="${FORCE:-0}"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
[[ "$(uname -s)" == "Linux" ]] || {
  echo "bench.sh needs Linux (/proc, iptables). On macOS use scripts/docker-run.sh." >&2; exit 1; }

say() { printf '==> %s\n' "$*" >&2; }
want() { [[ "$FORCE" == "1" || ! -x "$BIN/$1" ]]; }

if want goma; then
  say "goma $GOMA_VERSION ($ARCH)"
  curl -fsSL -o "$TMP/goma.tgz" \
    "https://github.com/jkaninda/goma-gateway/releases/download/${GOMA_VERSION}/goma-${GOMA_VERSION}-linux-${ARCH}.tar.gz"
  tar xzf "$TMP/goma.tgz" -C "$TMP" goma
  install -m755 "$TMP/goma" "$BIN/goma"
fi

if want traefik; then
  say "traefik $TRAEFIK_VERSION ($ARCH)"
  curl -fsSL -o "$TMP/traefik.tgz" \
    "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_${ARCH}.tar.gz"
  tar xzf "$TMP/traefik.tgz" -C "$TMP" traefik
  install -m755 "$TMP/traefik" "$BIN/traefik"
fi

if want fortio; then
  say "fortio $FORTIO_VERSION ($ARCH)"
  curl -fsSL -o "$TMP/fortio.tgz" \
    "https://github.com/fortio/fortio/releases/download/${FORTIO_VERSION}/fortio-linux_${ARCH}-${FORTIO_VERSION#v}.tgz"
  tar xzf "$TMP/fortio.tgz" -C "$TMP" usr/bin/fortio
  install -m755 "$TMP/usr/bin/fortio" "$BIN/fortio"
fi

say "benchtool (from source)"
( cd "$ROOT/tools/benchtool" && CGO_ENABLED=0 go build -trimpath -o "$BIN/benchtool" . )

for cmd in nginx haproxy taskset ss iptables; do
  command -v "$cmd" >/dev/null || say "NOTE: $cmd is not on PATH"
done

say "done:"
ls -la "$BIN" >&2
