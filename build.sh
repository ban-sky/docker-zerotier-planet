#!/usr/bin/env bash
#
# Build the multi-arch image locally or push it to a registry.
#
#   ./build.sh                 # build for the local architecture
#   PUSH=1 ./build.sh          # build amd64+arm64 and push
#   IMAGE=ghcr.io/me/zt ./build.sh   # e.g. after docker login
#
# GPLv3 - see LICENSE.
set -Eeuo pipefail

IMAGE="${IMAGE:-docker-zerotier-planet:latest}"
ZT_VERSION="${ZT_VERSION:-1.16.2}"
ZT_COMMIT="${ZT_COMMIT:-}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-0}"

die() { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[build] %s\n' "$*"; }

if [ -z "$ZT_COMMIT" ]; then
  case "$ZT_VERSION" in
    1.16.2) ZT_COMMIT="fc5c3ec22090b5b2a0f274e863651fe9ca489bf4" ;;
    *) die "set ZT_COMMIT to the commit for ZeroTier $ZT_VERSION" ;;
  esac
fi

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker buildx version >/dev/null 2>&1 || die "docker buildx is required"

log "building $IMAGE (ZeroTier $ZT_VERSION / $ZT_COMMIT)"

if [ "$PUSH" = "1" ]; then
  docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg "ZT_VERSION=$ZT_VERSION" \
    --build-arg "ZT_COMMIT=$ZT_COMMIT" \
    --tag "$IMAGE" \
    --push \
    "$@" .
else
  docker buildx build \
    --build-arg "ZT_VERSION=$ZT_VERSION" \
    --build-arg "ZT_COMMIT=$ZT_COMMIT" \
    --tag "$IMAGE" \
    --load \
    "$@" .
fi

log "done: $IMAGE"
