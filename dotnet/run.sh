#!/bin/bash
# Run one build in a Debian armhf container (podman + qemu-user on x86-64).
# Bookworm, because .NET 8's CoreCLR doesn't run on Debian sid's glibc 2.43.
#
# Usage: ./run.sh <coreclr|mono>
# Exit code is the program's: 0 = all jobs completed, anything else = failure
# (on Mono the expected outcome is a SIGSEGV, reported by Mono's crash handler).
#
# Mono's crash handler dumps the memory around the faulting instruction
# without checking that it is mapped. When it isn't (which varies from run to
# run here), the dump faults again inside the handler and the process hangs,
# so the program is stopped after TIMEOUT seconds (exit code 124).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
IMAGE=${IMAGE:-docker.io/library/debian:bookworm}
TIMEOUT=${TIMEOUT:-120}
RUNTIME=${1:-}

case "$RUNTIME" in
    coreclr|mono) ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
esac
[ -x "$ROOT/out/$RUNTIME/CrashDemo" ] || { echo "run ./build.sh first" >&2; exit 2; }

podman run --rm --platform linux/arm/v7 -v "$ROOT/out:/out:ro,Z" "$IMAGE" bash -c '
set -e
apt-get update -qq > /dev/null 2>&1
apt-get install -y -qq --no-install-recommends libstdc++6 > /dev/null 2>&1
cd /out/'"$RUNTIME"'
set +e
LD_LIBRARY_PATH=/out/'"$RUNTIME"' timeout -k 10 '"$TIMEOUT"' ./CrashDemo
rc=$?
if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "run.sh: CrashDemo did not exit within '"$TIMEOUT"' s and was stopped (Mono'"'"'s crash handler can hang after a crash)"
    rc=124
fi
exit $rc'
