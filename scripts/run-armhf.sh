#!/bin/bash
# Run the reproducer in an armhf (linux/arm/v7) Debian container with podman.
# On an x86-64 host this needs qemu-user-static registered with binfmt_misc
# (the F flag, so it works inside containers).
#
# Usage: scripts/run-armhf.sh <debian-release> <runtime> [iterations]
#   runtime: mono            the release's packaged mono
#            dotnet          .NET 10 (control)
#            mono-unpatched  mono-sgen cross-compiled by build-mono-armhf.sh
#            mono-patched    the same with patches/mono-arm-throw-fp-regs-offset.patch
#   e.g. scripts/run-armhf.sh sid mono
#        scripts/run-armhf.sh sid mono-patched
#
# Expects scripts/build.sh to have been run first; for dotnet also
# scripts/fetch-dotnet-armhf.sh, and for mono-unpatched/mono-patched also
# scripts/build-mono-armhf.sh for the same release. IMAGE overrides the
# container image, for example to pin a digest:
#   IMAGE=docker.io/library/debian@sha256:... scripts/run-armhf.sh sid mono
#
# Exit code is the reproducer's: 0 = pass, 1 = corruption detected.
set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,20p' "$0"
    exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/build}
DISTRO=$1
RUNTIME=$2
ITER=${3:-2000}
IMAGE=${IMAGE:-docker.io/library/debian:$DISTRO}

case "$RUNTIME" in
    mono) [ -f "$OUT/mono/Repro.exe" ] || { echo "run scripts/build.sh first" >&2; exit 2; } ;;
    dotnet) [ -x "$OUT/dotnet-arm/dotnet" ] || { echo "run scripts/fetch-dotnet-armhf.sh first" >&2; exit 2; } ;;
    mono-unpatched|mono-patched)
        [ -f "$OUT/mono/Repro.exe" ] || { echo "run scripts/build.sh first" >&2; exit 2; }
        [ -f "$OUT/mono-xbuild/${RUNTIME#mono-}/mono-sgen" ] || { echo "run scripts/build-mono-armhf.sh $DISTRO first" >&2; exit 2; }
        ;;
    *) echo "runtime must be mono, dotnet, mono-unpatched or mono-patched" >&2; exit 2 ;;
esac

podman run --rm --platform linux/arm/v7 \
    -v "$OUT:/work:ro,Z" \
    -v "$ROOT/scripts:/scripts:ro,Z" \
    "$IMAGE" \
    bash /scripts/in-container.sh "$RUNTIME" "$ITER"
