#!/bin/bash
# Runs inside the armhf container (see run-armhf.sh). /work is the build output.
# Usage: in-container.sh <mono|dotnet|mono-unpatched|mono-patched> <iterations>
set -euo pipefail

RUNTIME=$1
ITER=$2

echo "== environment"
echo "arch:   $(uname -m)"
echo "distro: $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "glibc:  $(ldd --version | head -1)"

case "$RUNTIME" in
    mono)
        echo "== installing mono-runtime"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends mono-runtime > /dev/null
        dpkg-query -W -f='package: ${Package} ${Version}\n' mono-runtime
        mono --version | head -1
        echo "== running"
        cd /work/mono
        LD_LIBRARY_PATH=/work/mono mono Repro.exe "$ITER"
        ;;
    mono-unpatched|mono-patched)
        VARIANT=${RUNTIME#mono-}
        echo "== installing mono-runtime (class libraries for the cross-compiled runtime)"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends mono-runtime > /dev/null
        dpkg-query -W -f='package: ${Package} ${Version}\n' mono-runtime
        HAVE=$(dpkg-query -W -f='${Version}' mono-runtime)
        WANT=$(cat /work/mono-xbuild/VERSION)
        if [ "$HAVE" != "$WANT" ]; then
            echo "mono-runtime $HAVE in this image does not match the cross-compiled source $WANT;" \
                 "rerun scripts/build-mono-armhf.sh for this release" >&2
            exit 2
        fi
        # Installed next to the packaged runtime so that it resolves its
        # libdir (and libmono-native.so) the same way.
        install -m 755 "/work/mono-xbuild/$VARIANT/mono-sgen" "/usr/bin/mono-sgen-$VARIANT"
        echo "runtime: cross-compiled mono $WANT, $VARIANT"
        "mono-sgen-$VARIANT" --version | head -1
        echo "== running"
        cd /work/mono
        LD_LIBRARY_PATH=/work/mono "mono-sgen-$VARIANT" Repro.exe "$ITER"
        ;;
    dotnet)
        export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
        /work/dotnet-arm/dotnet --list-runtimes
        echo "== running"
        cd /work/net10
        LD_LIBRARY_PATH=/work/net10 /work/dotnet-arm/dotnet Repro.dll "$ITER"
        ;;
esac
