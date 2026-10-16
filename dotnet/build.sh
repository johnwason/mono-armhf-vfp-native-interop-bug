#!/bin/bash
# Build the example on an x86-64 host. Needs only podman: everything runs in
# the .NET 8 SDK container (x86-64), with the armhf cross compiler added.
#
#   out/coreclr/   self-contained linux-arm app on CoreCLR (control)
#   out/mono/      the same app on .NET's Mono runtime (UseMonoRuntime=true)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
IMAGE=${SDK_IMAGE:-mcr.microsoft.com/dotnet/sdk:8.0}

rm -rf "$ROOT/out"
mkdir -p "$ROOT/out"
podman run --rm --platform linux/amd64 -v "$ROOT:/demo:Z" -w /demo \
    -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 \
    "$IMAGE" bash -c '
set -euo pipefail
apt-get update -qq
apt-get install -y -qq --no-install-recommends gcc-arm-linux-gnueabihf libc6-dev-armhf-cross > /dev/null
arm-linux-gnueabihf-gcc -O2 -Wall -shared -fPIC -o out/libworker.so native/worker.c native/keep_in_d8.S
cd managed
dotnet publish -c Release -o ../out/coreclr --nologo -v quiet
dotnet publish -c Release -o ../out/mono -p:UseMonoRuntime=true --nologo -v quiet
cp ../out/libworker.so ../out/coreclr/
cp ../out/libworker.so ../out/mono/
rm -rf bin obj
'
echo "built out/coreclr and out/mono"
