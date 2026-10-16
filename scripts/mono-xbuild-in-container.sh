#!/bin/bash
# Runs inside an x86-64 Debian container (see build-mono-armhf.sh).
# /x is the output directory, /patches holds the fix.
# Usage: mono-xbuild-in-container.sh <jobs>
set -euo pipefail

JOBS=$1

if [ "$(dpkg --print-architecture)" != amd64 ]; then
    echo "the build container must be amd64, got $(dpkg --print-architecture)" >&2
    exit 2
fi

echo "== installing armhf cross toolchain"
export DEBIAN_FRONTEND=noninteractive
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
dpkg --add-architecture armhf
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    dpkg-dev ca-certificates xz-utils patch file \
    crossbuild-essential-armhf zlib1g-dev:armhf \
    autoconf automake libtool libtool-bin autopoint gettext cmake python3 make gcc g++ pkg-config \
    > /dev/null
arm-linux-gnueabihf-gcc --version | head -1

echo "== fetching Debian mono source"
rm -rf /x/src /x/build /x/unpatched /x/patched /x/VERSION
mkdir -p /x/src /x/build /x/unpatched /x/patched
cd /x/src
apt-get source -qq mono 2>&1 | grep -v '^W: Download is performed unsandboxed' || true
SRC=$(echo /x/src/mono-*/)
VERSION=$(dpkg-parsechangelog -l "$SRC/debian/changelog" -S Version)
echo "source: mono $VERSION"

echo "== configuring (runtime only, cross x86-64 -> armhf)"
(cd "$SRC" && NOCONFIGURE=1 ./autogen.sh > /x/build/autogen.log 2>&1)
cd /x/build
# The paths match Debian's package so the runtime finds /etc/mono/config and
# /usr/lib/mono in the test container. --sysconfdir matters: without it the
# runtime looks for /usr/etc/mono/config, misses the System.Native dllmap and
# throws DllNotFoundException the first time it formats a double.
"$SRC/configure" --build=x86_64-linux-gnu --host=arm-linux-gnueabihf \
    --prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib --sysconfdir=/etc --localstatedir=/var \
    --with-tls=pthread --with-sgen=yes --disable-boehm --disable-btls \
    --disable-mcs-build --disable-nls --with-ikvm-native=no \
    --enable-llvm=no --enable-loadedllvm=no --disable-system-aot --with-libatomic-ops=none \
    > /x/build/configure.log 2>&1 || { tail -50 /x/build/configure.log; exit 1; }

echo "== building unpatched runtime"
make -j"$JOBS" -C mono > /x/build/make-unpatched.log 2>&1 || { tail -50 /x/build/make-unpatched.log; exit 1; }
arm-linux-gnueabihf-strip -o /x/unpatched/mono-sgen mono/mini/mono-sgen

echo "== applying patch and rebuilding"
patch -p1 -d "$SRC" < /patches/mono-arm-throw-fp-regs-offset.patch
make -j"$JOBS" -C mono > /x/build/make-patched.log 2>&1 || { tail -50 /x/build/make-patched.log; exit 1; }
arm-linux-gnueabihf-strip -o /x/patched/mono-sgen mono/mini/mono-sgen

if cmp -s /x/unpatched/mono-sgen /x/patched/mono-sgen; then
    echo "patched and unpatched binaries are identical; the patch had no effect" >&2
    exit 1
fi

echo "$VERSION" > /x/VERSION
file /x/unpatched/mono-sgen
ls -l /x/unpatched/mono-sgen /x/patched/mono-sgen
echo "== done: mono $VERSION"
