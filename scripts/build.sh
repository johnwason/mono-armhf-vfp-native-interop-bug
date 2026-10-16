#!/bin/bash
# Build everything on an x86-64 host:
#   build/libnative.so        armhf native library (cross-compiled)
#   build/mono/Repro.exe      managed reproducer for mono (+ a copy of libnative.so)
#   build/net10/Repro.dll     the same source for .NET 10 (+ a copy of libnative.so)
#
# Requires: arm-linux-gnueabihf-gcc and binutils, mcs (mono-mcs), dotnet SDK 10.
# Override tools with CROSS_PREFIX, MCS, DOTNET; output directory with OUT.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/build}
CROSS_PREFIX=${CROSS_PREFIX:-arm-linux-gnueabihf-}
MCS=${MCS:-mcs}
DOTNET=${DOTNET:-dotnet}

rm -rf "$OUT/mono" "$OUT/net10" "$OUT/libnative.so" "$OUT/loop_check.disasm"
mkdir -p "$OUT/mono" "$OUT/net10"

echo "== native (armhf)"
"${CROSS_PREFIX}gcc" --version | head -1
"${CROSS_PREFIX}gcc" -O2 -Wall -shared -fPIC -o "$OUT/libnative.so" \
    "$ROOT/native/native.c" "$ROOT/native/probe.S" -lpthread
file "$OUT/libnative.so" 2>/dev/null || true

# The realistic check only means something if the compiler really keeps the
# local in a callee-saved VFP register across the call. Record and verify that.
"${CROSS_PREFIX}objdump" -d --no-show-raw-insn "$OUT/libnative.so" \
    | sed -n '/<loop_check>:/,/^$/p' > "$OUT/loop_check.disasm"
cat "$OUT/loop_check.disasm"
if grep -qE 'vpush.*\{d8' "$OUT/loop_check.disasm"; then
    echo "loop_check keeps its local in a callee-saved VFP register (vpush {d8...}): OK"
else
    echo "WARNING: loop_check does not use d8 with this compiler; only the exact probe is meaningful" >&2
fi

echo "== managed (mono)"
"$MCS" --version
"$MCS" -nologo -optimize+ -out:"$OUT/mono/Repro.exe" "$ROOT/managed/Repro.cs"
cp "$OUT/libnative.so" "$OUT/mono/"

echo "== managed (.NET 10)"
"$DOTNET" --version
"$DOTNET" build "$ROOT/managed/Repro.csproj" -c Release -o "$OUT/net10" --nologo -v quiet
cp "$OUT/libnative.so" "$OUT/net10/"

echo "== done"
ls -l "$OUT" "$OUT/mono" "$OUT/net10"
