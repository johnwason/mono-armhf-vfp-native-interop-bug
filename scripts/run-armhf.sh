#!/bin/bash
# Run the reproducer in an armhf (linux/arm/v7) Debian container with podman.
# On an x86-64 host this needs qemu-user-static registered with binfmt_misc
# (the F flag, so it works inside containers).
#
# Usage: scripts/run-armhf.sh <debian-release> <mono|dotnet> [iterations]
#   e.g. scripts/run-armhf.sh sid mono
#        scripts/run-armhf.sh sid dotnet
#
# Expects scripts/build.sh (and, for dotnet, scripts/fetch-dotnet-armhf.sh) to
# have been run first. IMAGE overrides the container image, for example to pin
# a digest: IMAGE=docker.io/library/debian@sha256:... scripts/run-armhf.sh sid mono
#
# Exit code is the reproducer's: 0 = pass, 1 = corruption detected.
set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,14p' "$0"
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
    *) echo "runtime must be mono or dotnet" >&2; exit 2 ;;
esac

podman run --rm --platform linux/arm/v7 \
    -v "$OUT:/work:ro,Z" \
    -v "$ROOT/scripts:/scripts:ro,Z" \
    "$IMAGE" \
    bash /scripts/in-container.sh "$RUNTIME" "$ITER"
