#!/bin/bash
# Download the armhf (linux-arm) .NET runtime into build/dotnet-arm on the host,
# so the armhf container needs no network access or SDK for the .NET run.
# (The .NET SDK itself does not run reliably under qemu-arm; MSBuild hits a
# stack overflow. Only the runtime is needed here.)
#
# Override the channel with DOTNET_CHANNEL (default 10.0), or pin an exact
# runtime with DOTNET_VERSION.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/build}
DOTNET_CHANNEL=${DOTNET_CHANNEL:-10.0}

mkdir -p "$OUT"
curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$OUT/dotnet-install.sh"

args=(--runtime dotnet --architecture arm --os linux --install-dir "$OUT/dotnet-arm" --no-path)
if [ -n "${DOTNET_VERSION:-}" ]; then
    args+=(--version "$DOTNET_VERSION")
else
    args+=(--channel "$DOTNET_CHANNEL")
fi

rm -rf "$OUT/dotnet-arm"
bash "$OUT/dotnet-install.sh" "${args[@]}"
ls "$OUT/dotnet-arm/shared/Microsoft.NETCore.App"
