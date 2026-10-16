#!/bin/bash
# Cross-compile mono's runtime (mono-sgen) for armhf on an x86-64 host, twice
# from the same Debian source package: once unmodified and once with
# patches/mono-arm-throw-fp-regs-offset.patch applied.
#
#   build/mono-xbuild/unpatched/mono-sgen
#   build/mono-xbuild/patched/mono-sgen
#   build/mono-xbuild/VERSION     Debian source version that was built
#
# Only the runtime is built. The class libraries come from the same version's
# mono-runtime package in the armhf test container, so the source version must
# match what that container installs: build from the same Debian release you
# test on (default sid).
#
# Usage: scripts/build-mono-armhf.sh [debian-release]
# Needs podman. Runs the build in an x86-64 Debian container, no emulation.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/build}
DISTRO=${1:-sid}
IMAGE=${BUILD_IMAGE:-docker.io/library/debian:$DISTRO}

mkdir -p "$OUT/mono-xbuild"
podman run --rm --platform linux/amd64 \
    -v "$ROOT/scripts:/scripts:ro,Z" \
    -v "$ROOT/patches:/patches:ro,Z" \
    -v "$OUT/mono-xbuild:/x:Z" \
    "$IMAGE" \
    bash /scripts/mono-xbuild-in-container.sh "$(nproc)"
