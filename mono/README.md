# Classic mono on armhf: register probe and patch verification

This folder reproduces the bug described in the [top-level README](../README.md) with classic mono, as packaged by Debian. It has two parts:

- **A register probe.** An assembly routine loads a distinct pattern into every callee-saved register, calls a managed callback through a delegate, and reports exactly what changed. It runs against mono 6.8, 6.12 and 6.14 from Debian bookworm, trixie and sid, with .NET 10 (CoreCLR) as the control.
- **Patch verification.** It cross-compiles Debian sid's mono runtime twice, unmodified and with [`patches/mono-arm-throw-fp-regs-offset.patch`](patches/mono-arm-throw-fp-regs-offset.patch), and runs the probe with each.

| Runtime (Debian armhf) | `throw_catch`, `throw_catch_nested`, `rethrow` | `plain`, `try_finally`, `index_oob` |
|---|---|---|
| mono 6.8.0.105 (bookworm) | **corrupted**, 2000/2000 calls | correct |
| mono 6.12.0.199 (trixie) | **corrupted**, 2000/2000 calls | correct |
| mono 6.14.1 (sid) | **corrupted**, 2000/2000 calls | correct |
| mono 6.14.1 from source, unmodified | **corrupted**, 2000/2000 calls | correct |
| mono 6.14.1 from source, patched | correct | correct |
| .NET 10.0.13, same native library and C# source | correct | correct |

The workflow [`.github/workflows/mono.yml`](../.github/workflows/mono.yml) runs all six. Each job passes when its result is the expected one.

## The corruption pattern

The probe loads a distinct pattern into each of `d7`–`d15` before calling the callback, then reads them back after the callback returns. With mono, every call whose callback caught an exception comes back like this:

| Register | Holds after the call |
|---|---|
| `d8` | the value `d7` had when the exception was thrown (usually the caller's `d7`) |
| `d9` | the caller's `d8` |
| `d10` | the caller's `d9` |
| … | … |
| `d15` | the caller's `d14` |

All eight registers move up by one: `d(n+1)` receives the caller's `d(n)`. The output's `shifted` column counts calls that match this exactly.

`d7` is caller-saved, so the managed code between the native call and the `throw` may change it. Usually nothing does, and `d8` receives the native caller's `d7`. The exception is the first `throw` on each thread: the runtime does extra work before it reaches the throw, `d7` changes, and that one call doesn't match the shift exactly. That is why `throw_catch` shows 1999/2000 on both threads, `throw_catch_nested` shows 1999/2000 on the new pthread, and `throw_catch_nested` on the main thread, which already threw in the `throw_catch` row, shows 2000/2000.

`rethrow` passes through the faulty trampoline twice, so its registers move up by **two** (`d(n+2)` receives the caller's `d(n)`). Its `shifted` count is 0 because that column only looks for a one-register shift, but every call is corrupted.

## What the reproducer does

[`managed/Repro.cs`](managed/Repro.cs) passes six delegates to native code:

| Callback | Body |
|---|---|
| `plain` | increments a field (control) |
| `try_finally` | a `try`/`finally` with no exception (control) |
| `index_oob` | catches an `IndexOutOfRangeException` from an array bounds check. Mono raises these through its corlib trampoline, which isn't affected (control) |
| `throw_catch` | `try { throw new InvalidOperationException(); } catch (InvalidOperationException) { }` |
| `throw_catch_nested` | the same, but the exception is thrown from a separate non-inlined method |
| `rethrow` | throws, rethrows with `throw;` from a `catch`, and catches in an outer handler |

[`native/native.c`](native/native.c) calls each one 2000 times in two ways, each from the main thread and from a new pthread the runtime has never seen:

1. **Exact probe** ([`native/probe.S`](native/probe.S)). An assembly routine:
   - saves the real callee-saved registers;
   - loads known, per-call patterns into `d8`–`d15` and `r4`–`r11`, a canary into its own stack frame, and a marker into `d7`;
   - calls the callback;
   - records what is in those registers and that stack slot afterwards, then restores everything and returns.

   Being written in assembly, it doesn't depend on how a given GCC version allocates registers. It reports per register how many calls changed it and the first wrong value, plus the `shifted` count.
2. **Compiler-generated loop** (`loop_check`). An ordinary C loop whose local `double` lives in `d8` across the call. This is the pattern in which the bug was hit in practice. The build script disassembles it and warns if the compiler didn't use `d8`. Because `d8` receives `d7`, this count depends on what the compiled loop leaves in `d7`. After a single `throw`, only the first iteration or two fail, because the loop's own compare leaves the expected value in `d7` for later calls. After a rethrow, `d8` receives `d6` and every iteration fails. The exact probe is the authoritative measurement.

The same `Repro.cs` is compiled with `mcs` for mono and with the .NET 10 SDK for the control. The same `libnative.so` binary is used for both.

## Running it

Everything runs from this folder, on an x86-64 Linux host.

Requirements:
- podman;
- `qemu-user-static` registered with binfmt_misc using the `F` flag. The Debian and Ubuntu packages do this; check `/proc/sys/fs/binfmt_misc/qemu-arm`.
- For the build step: `gcc-arm-linux-gnueabihf`, `binutils-arm-linux-gnueabihf`, `libc6-dev-armhf-cross`, `mono-mcs`, `curl` and a .NET 10 SDK.

```bash
./scripts/build.sh                # cross-compile native + managed into build/
./scripts/fetch-dotnet-armhf.sh   # linux-arm .NET runtime into build/dotnet-arm (for the control)

./scripts/run-armhf.sh sid mono       # mono 6.14  -> RESULT: FAIL, exit 1
./scripts/run-armhf.sh trixie mono    # mono 6.12  -> RESULT: FAIL, exit 1
./scripts/run-armhf.sh bookworm mono  # mono 6.8   -> RESULT: FAIL, exit 1
./scripts/run-armhf.sh sid dotnet     # .NET 10    -> RESULT: PASS, exit 0
```

If the build tools aren't installed, the build step can run in a container that matches the GitHub runner:

```bash
podman run --rm -v "$PWD:/repo:Z" -w /repo -e DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
  docker.io/library/ubuntu:24.04 bash -c '
    apt-get update -qq &&
    apt-get install -y -qq --no-install-recommends gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
      libc6-dev-armhf-cross mono-mcs curl ca-certificates file &&
    curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 --install-dir /opt/dotnet &&
    PATH=/opt/dotnet:$PATH ./scripts/build.sh && ./scripts/fetch-dotnet-armhf.sh'
```

`run-armhf.sh` takes an optional third argument, the number of iterations per row (default 2000). Set `IMAGE` to use a different or pinned image, for example `IMAGE=docker.io/library/debian@sha256:… ./scripts/run-armhf.sh sid mono`.

### Verifying the fix

[`scripts/build-mono-armhf.sh`](scripts/build-mono-armhf.sh) cross-compiles mono's runtime for armhf in an x86-64 Debian container, so nothing runs under emulation and the build takes minutes rather than hours. It:

- fetches the Debian source package for `mono` (`apt-get source`);
- configures a runtime-only cross build (`--host=arm-linux-gnueabihf`, no class libraries) with Debian's paths;
- builds `mono-sgen`, applies [the patch](patches/mono-arm-throw-fp-regs-offset.patch), and builds it again.

Debian's armhf `mono-sgen` has the runtime linked in statically, so the test only replaces that one binary. The class libraries and `libmono-native.so` come from the `mono-runtime` package in the armhf container. Mono rejects class libraries from a different version, so build from the same Debian release you test on; `in-container.sh` checks that the versions match.

```bash
./scripts/build.sh                     # reproducer, if not already built
./scripts/build-mono-armhf.sh sid      # build/mono-xbuild/{unpatched,patched}/mono-sgen

./scripts/run-armhf.sh sid mono-unpatched   # -> RESULT: FAIL, exit 1
./scripts/run-armhf.sh sid mono-patched     # -> RESULT: PASS, exit 0
```

Only Debian sid (mono 6.14.1) is built. The same code is in 6.8 and 6.12, but their source packages haven't been tried with this script.

### On real armhf hardware

Copy this folder to the device (for example a Raspberry Pi running a 32-bit OS, or an armhf container on a 64-bit Pi) and build natively:

```bash
sudo apt-get install gcc libc6-dev mono-mcs mono-runtime
gcc -O2 -shared -fPIC -o libnative.so native/native.c native/probe.S -lpthread
mcs -out:Repro.exe managed/Repro.cs
LD_LIBRARY_PATH=. mono Repro.exe
```

## Reading the output

The reference logs in [`results/`](results/) come from runs under qemu on an x86-64 host; GitHub Actions produces identical result tables. Trimmed mono 6.14.1 output:

```
Runtime:    Mono 6.14.1 (tarball Wed May  6 01:19:19 UTC 2026)
Iterations: 2000 per row

Exact probe: calls in which a callee-saved register or the caller's stack slot changed
  'shifted' = calls where d8-d15 came back as the caller's d7-d14, i.e. moved up one register
callback             thread          bad calls    shifted  changed (calls, first value seen)
plain                main               0/2000     0/2000  -
...
index_oob            main               0/2000     0/2000  -
index_oob            native pthread     0/2000     0/2000  -
throw_catch          main            2000/2000  1999/2000  d8(2000, 0x4070200000000000 = 258) d9(2000, 0x4d080000000000d0 = ...) ... d15(2000, ...)
throw_catch          native pthread  2000/2000  1999/2000  d8(2000, 0x40f6666640000000 = 91750.390625) d9(2000, ...) ... d15(2000, ...)
throw_catch_nested   main            2000/2000  2000/2000  d8(2000, 0x4d070000000000d0 = ...) d9(2000, ...) ... d15(2000, ...)
throw_catch_nested   native pthread  2000/2000  1999/2000  d8(2000, ...) ... d15(2000, ...)
rethrow              main            2000/2000     0/2000  d8(2000, 0x4036000000000000 = 22) d9(2000, 0x4d070000000000d0 = ...) d10(2000, 0x4d080000000000d0 = ...) ...
rethrow              native pthread  2000/2000     0/2000  d8(2000, ...) ... d15(2000, ...)

Compiler-generated loop: iterations in which a C local held in d8 across the call changed
callback             thread          bad iters  first wrong value
...
throw_catch          main               1/2000  1.6021944205688904E-306
...
rethrow              main            2000/2000  4.4505763678057458E-308
...

RESULT: FAIL - callee-saved state was corrupted across a managed callback (AAPCS-VFP violation)
```

- **bad calls**: calls after which any of `d8`–`d15`, `r4`–`r11` or the stack canary differed from what was loaded before the call.
- **shifted**: calls whose `d8`–`d15` match the one-register shift exactly.
- **changed**: for each register that changed, how many calls changed it and the first wrong value seen, in hex and as a double.

The probe's patterns start with `0x4d0` followed by the register number in hex, so `0x4d08…` was loaded into `d8`, `0x4d0f…` into `d15` and `0x4d07…` into `d7`. In the example, `d9`'s first wrong value after `throw_catch` is `0x4d08…`, which is `d8`'s pattern. After `rethrow`, `d9` holds `d7`'s pattern and `d10` holds `d8`'s. The first wrong `d8` values that aren't patterns (`258`, `91750.390625`, `22`) come from the first throw on each thread, described under [The corruption pattern](#the-corruption-pattern).

**Exit codes:** `0` means no corruption, `1` means corruption detected, `2` means a usage or setup error.

## Notes and limitations

- **qemu and hardware agree.** An earlier version of this test gave identical results on a Raspberry Pi (64-bit kernel, armhf userland in podman) for mono 6.8, 6.12 and 6.14.1. That covered the `d8` clobber, the same first wrong values, and .NET 10 passing. Under qemu the output is identical from run to run, on the local host and on GitHub's runners.
- **What is and isn't tested.** It doesn't cover:
  - exceptions that escape the callback into native code, which is undefined anyway;
  - `catch` with a `when` filter;
  - async code;
  - a `NullReferenceException`. On Linux/ARM, mono compiles null checks as explicit checks, which raise it through the same unaffected trampoline as `index_oob`. Testing it separately confirmed it isn't affected.
- **The stack is preserved in this test.** The probe's own stack canary is never corrupted here. An earlier test saw one value kept in the caller's stack frame corrupted on mono 6.8 and 6.12, but not 6.14.1. That isn't reproduced by this probe and may depend on the exact frame layout.
- **.NET details:**
  - .NET 8 does not run on Debian sid armhf at all. Its thread pool dies with SIGBUS on `ldrexd` in glibc 2.43's `pthread_cond_wait`. That is a separate .NET 8 / glibc issue, and is why the control uses .NET 10.
  - The .NET SDK doesn't run reliably under qemu-arm: MSBuild hits a stack overflow. That is why the .NET program is built on x86-64; the compiled output is portable, so only the runtime runs under emulation.
- **Debian sid changes over time.** To keep a demonstration stable, pin the image by digest with `IMAGE`. For the patch verification, the cross-compiled source and the container's `mono-runtime` must be the same version, so build and test on the same day or pin both images.

## Layout

| Path | Contents |
|---|---|
| `native/probe.S` | assembly probe: loads, calls, records `d8`–`d15`, `r4`–`r11`, a stack canary |
| `native/native.c` | probe driver, shift detection, compiler-generated `d8` loop, pthread variants |
| `managed/Repro.cs` | callbacks and result reporting; compiles with `mcs` and the .NET SDK |
| `managed/Repro.csproj` | .NET 10 project for the same source |
| `patches/mono-arm-throw-fp-regs-offset.patch` | the fix for mono's `exceptions-arm.c` |
| `scripts/build.sh` | cross-compiles and builds the reproducer into `build/` on x86-64 |
| `scripts/fetch-dotnet-armhf.sh` | downloads the `linux-arm` .NET runtime into `build/dotnet-arm` |
| `scripts/build-mono-armhf.sh` | cross-compiles Debian's mono runtime for armhf, unpatched and patched, into `build/mono-xbuild` |
| `scripts/mono-xbuild-in-container.sh` | the part of that build that runs inside the x86-64 container |
| `scripts/run-armhf.sh` | runs one runtime in a Debian armhf container with podman |
| `scripts/in-container.sh` | the part that runs inside the armhf container |
| `results/` | reference logs from qemu on x86-64 for all six cases, plus the cross-compiled `loop_check` disassembly |
