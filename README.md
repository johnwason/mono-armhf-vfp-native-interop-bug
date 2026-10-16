# mono on armhf corrupts callee-saved VFP registers after a caught exception in a native-to-managed callback

On 32-bit ARM hard-float Linux (armhf), when native code calls a managed callback through a delegate (reverse P/Invoke) and that callback throws **and catches** an exception, mono returns to the native caller with the callee-saved VFP registers `d8`–`d15` corrupted.

The ARM procedure call standard (AAPCS / AAPCS-VFP) requires a callee to preserve `d8`–`d15`, the same as `r4`–`r11`. Compiled native code relies on this. A value it keeps in `d8` across the call is silently replaced, and the result is wrong arithmetic or, as in the case that led to this report, a segfault inside an unrelated library.

**Cause:** mono's ARM throw trampoline passes the saved floating-point registers to the exception handler through a pointer that is 8 bytes too low, so the catch handler resumes with every VFP register shifted by one. A one-line fix is in [`patches/`](patches/mono-arm-throw-fp-regs-offset.patch). See [Root cause and fix](#root-cause-and-fix).

| Runtime (Debian armhf) | Result |
|---|---|
| mono 6.8.0.105 (bookworm) | **corrupted**, every call that catches an exception |
| mono 6.12.0.199 (trixie) | **corrupted**, every call that catches an exception |
| mono 6.14.1 (sid) | **corrupted**, every call that catches an exception |
| mono 6.14.1 built from Debian's source, unmodified | **corrupted**, same as the package |
| mono 6.14.1 built from Debian's source, with the patch | correct |
| .NET 10.0.13, same native library and same C# source | correct |

Callbacks that don't throw, including ones with a `try`/`finally`, are not affected. The integer callee-saved registers `r4`–`r11` are not affected, and neither is the probe's stack canary.

This repository contains a self-contained reproducer, about 400 lines of C, assembly and C#, and two GitHub Actions workflows that run on armhf **without ARM hardware**: one runs the reproducer against Debian's mono packages and .NET 10, the other cross-compiles mono with and without the fix and compares them. Both cross-compile on x86-64 and run the results in Debian armhf containers with podman and qemu-user.

## Contents

- [The corruption pattern](#the-corruption-pattern)
- [Root cause and fix](#root-cause-and-fix)
- [What the reproducer does](#what-the-reproducer-does)
- [Running it](#running-it)
- [Reading the output](#reading-the-output)
- [How this was found](#how-this-was-found)
- [Notes and limitations](#notes-and-limitations)
- [Workarounds](#workarounds)
- [Repository layout](#repository-layout)

## The corruption pattern

The exact probe loads a distinct pattern into each of `d7`–`d15` before calling the callback, then reads them back after the callback returns. With mono, every call whose callback caught an exception comes back like this:

| Register | Holds after the call |
|---|---|
| `d8` | the value `d7` had when the exception was thrown (usually the caller's `d7`) |
| `d9` | the caller's `d8` |
| `d10` | the caller's `d9` |
| … | … |
| `d15` | the caller's `d14` |

All eight registers move up by one: `d(n+1)` receives the caller's `d(n)`. The output's `shifted` column counts calls that match this exactly. It is 1999 or 2000 out of 2000 on every mono version tested.

`d7` is caller-saved, so the managed code between the native call and the `throw` may change it. Usually nothing does, and `d8` receives the native caller's `d7`. The exception is the first exception thrown on each thread: the runtime does extra work before it reaches the throw, `d7` changes, and that one call doesn't match the shift exactly. That is why `throw_catch` shows 1999/2000 on both threads, `throw_catch_nested` shows 1999/2000 on the new pthread, and `throw_catch_nested` on the main thread, which already threw in the `throw_catch` row, shows 2000/2000.

In native code, `d7` holds whatever scratch value the caller happened to leave there. In the original crash, those were small floats such as `438.0f` and `1302.7f` written over a pointer.

## Root cause and fix

The bug is in `get_throw_trampoline ()` in [`mono/mini/exceptions-arm.c`](https://github.com/mono/mono/blob/main/mono/mini/exceptions-arm.c#L224-L298). Line numbers below are from mono 6.14.1, which matches mono/mono `main`; in 6.12.0.199 the trampoline is at the same lines and in 6.8.0.105 one line earlier.

When managed code throws, the trampoline:

1. pushes `r4`–`r12` and `lr` (40 bytes);
2. stores `d0`–`d15` at `SP` (L249, 128 bytes);
3. reserves a parameter area below them (L253–258). For the throw and rethrow trampolines it holds an extra `preserve_ips` argument, so it is 12 bytes, and `ALIGN_TO (cfa_offset + param_size, 8)` rounds it up to **16**;
4. passes the address of the saved FP registers to `mono_arm_throw_exception ()` as **`SP + 8`** (L290, L298).

The saved registers are at `SP + 16`, so the pointer is one 8-byte slot too low:

```
higher addresses
  saved d15
  ...
  saved d0        <- SP + 16   where the registers really are
  padding         <- SP + 8    fp_regs pointer passed to mono_arm_throw_exception
  args            <- SP
lower addresses
```

`mono_arm_throw_exception ()` copies 16 doubles from that pointer into `ctx.fregs` (L168), so `fregs[0]` is padding and `fregs[n]` is the saved `d(n-1)`. On Linux the unwinder doesn't touch `fregs[8..15]` (that code is `#ifdef TARGET_IOS`, L495–515), and `restore_context` reloads all 16 registers from `ctx.fregs` (L72–73) before jumping to the catch handler. Every VFP register comes back as its lower neighbour.

Mono's own code never notices: on armhf the JIT doesn't allocate `d8`–`d15` at all ([`mini-arm.h`](https://github.com/mono/mono/blob/main/mono/mini/mini-arm.h#L68-L82)), so managed code neither uses them nor saves them. The corrupted values pass straight through to the native caller when the callback returns.

The hard-coded `8` is only correct when the parameter area is 8 bytes, as it still is for the corlib and resume-unwind trampolines. The fix is to use the computed size:

```diff
-		ARM_ADD_REG_IMM8 (code, ARMREG_LR, ARMREG_SP, 8);
+		ARM_ADD_REG_IMM8 (code, ARMREG_LR, ARMREG_SP, param_size);
```

in both branches. The full patch with a description is [`patches/mono-arm-throw-fp-regs-offset.patch`](patches/mono-arm-throw-fp-regs-offset.patch). It applies with `patch -p1` to Debian's mono 6.14.1 source and to [mono/mono](https://github.com/mono/mono) `main`.

The same code is in mono 6.8.0.105, 6.12.0.199 and 6.14.1, and in the Mono runtime in [dotnet/runtime](https://github.com/dotnet/runtime) (`src/mono/mono/mini/exceptions-arm.c`, same lines).

**Verification.** The [patch verification workflow](.github/workflows/mono-patch.yml) builds Debian sid's mono 6.14.1 runtime for armhf twice, unmodified and patched, and runs the reproducer with each. The unmodified build reproduces the corruption exactly as the Debian package does, and the patched build passes every row of both checks. See [Verifying the fix](#verifying-the-fix).

## What the reproducer does

[`managed/Repro.cs`](managed/Repro.cs) passes four delegates to native code:

| Callback | Body |
|---|---|
| `plain` | increments a field (control) |
| `try_finally` | a `try`/`finally` with no exception (control) |
| `throw_catch` | `try { throw new InvalidOperationException(); } catch (InvalidOperationException) { }` |
| `throw_catch_nested` | the same, but the exception is thrown from a separate non-inlined method |

[`native/native.c`](native/native.c) calls each one 2000 times in two ways, each from the main thread and from a new pthread the runtime has never seen:

1. **Exact probe** ([`native/probe.S`](native/probe.S)). An assembly routine:
   - saves the real callee-saved registers;
   - loads known, per-call patterns into `d8`–`d15` and `r4`–`r11`, a canary into its own stack frame, and a marker into `d7`;
   - calls the callback;
   - records what is in those registers and that stack slot afterwards, then restores everything and returns.

   Being written in assembly, it doesn't depend on how a given GCC version allocates registers. It reports per register how many calls changed it and the first wrong value, plus the `shifted` count described above.
2. **Compiler-generated loop** (`loop_check`). An ordinary C loop whose local `double` lives in `d8` across the call. This is the pattern in which the bug was hit in practice. The build script disassembles it and warns if the compiler didn't use `d8`. Because `d8` receives `d7`, this count depends on what the compiled loop leaves in `d7`. With the GCC versions tested, only the first iteration fails (`1/2000`), because the loop's own compare leaves the expected value in `d7` for every later call. That's expected; the exact probe is the authoritative measurement.

The same `Repro.cs` is compiled with `mcs` for mono and with the .NET 10 SDK for the control. The same `libnative.so` binary is used for both.

## Running it

### In GitHub Actions (no ARM hardware)

Push this repository to GitHub. Both workflows run on push, on pull requests and manually from the **Actions** tab, with an optional iteration count.

[`.github/workflows/armhf-repro.yml`](.github/workflows/armhf-repro.yml) (**armhf mono VFP register corruption**) has two stages:

1. **build** (`ubuntu-24.04`, x86-64):
   - cross-compiles `libnative.so` with `gcc-arm-linux-gnueabihf`;
   - compiles `Repro.exe` with `mcs` and `Repro.dll` with the .NET 10 SDK;
   - downloads the `linux-arm` .NET runtime.
2. **test**: four jobs, each of which installs `qemu-user-static` and runs the build output in a `linux/arm/v7` Debian container with podman:

   | Job | Runtime |
   |---|---|
   | mono on Debian sid | mono 6.14 |
   | mono on Debian trixie | mono 6.12 |
   | mono on Debian bookworm | mono 6.8 |
   | dotnet on Debian sid | .NET 10 (control) |

Each test job **fails if corruption is detected**. A run that demonstrates the bug therefore shows the three mono jobs failing and the .NET job passing. Every job writes its result table to the run's summary page and uploads its full log as an artifact.

[`.github/workflows/mono-patch.yml`](.github/workflows/mono-patch.yml) (**armhf mono patch verification**) is described in [Verifying the fix](#verifying-the-fix). It **passes** when the fix works.

### Locally on an x86-64 Linux machine

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

The workflow does the same and passes only if the unpatched build fails and the patched build passes. Only Debian sid (mono 6.14.1) is built; the same code is in 6.8 and 6.12, but their source packages haven't been tried with this script.

### On real armhf hardware

Copy the repository to the device (for example a Raspberry Pi running a 32-bit OS, or an armhf container on a 64-bit Pi) and build natively:

```bash
sudo apt-get install gcc libc6-dev mono-mcs mono-runtime
gcc -O2 -shared -fPIC -o libnative.so native/native.c native/probe.S -lpthread
mcs -out:Repro.exe managed/Repro.cs
LD_LIBRARY_PATH=. mono Repro.exe
```

## Reading the output

The reference logs in [`results/`](results/) come from a run under qemu on an x86-64 host. The GitHub Actions runs produce identical result tables. Trimmed mono 6.14.1 output:

```
Runtime:    Mono 6.14.1 (tarball Wed May  6 01:19:19 UTC 2026)
Iterations: 2000 per row

Exact probe: calls in which a callee-saved register or the caller's stack slot changed
  'shifted' = calls where d8-d15 came back as the caller's d7-d14, i.e. moved up one register
callback             thread          bad calls    shifted  changed (calls, first value seen)
plain                main               0/2000     0/2000  -
plain                native pthread     0/2000     0/2000  -
try_finally          main               0/2000     0/2000  -
try_finally          native pthread     0/2000     0/2000  -
throw_catch          main            2000/2000  1999/2000  d8(2000, 0x406fe00000000000 = 255) d9(2000, 0x4d080000000000d0 = ...) ... d15(2000, ...)
throw_catch          native pthread  2000/2000  1999/2000  d8(2000, 0x40f6666640000000 = 91750.390625) d9(2000, ...) ... d15(2000, ...)
throw_catch_nested   main            2000/2000  2000/2000  d8(2000, 0x4d070000000000d0 = ...) d9(2000, ...) ... d15(2000, ...)
throw_catch_nested   native pthread  2000/2000  1999/2000  d8(2000, ...) ... d15(2000, ...)

Compiler-generated loop: iterations in which a C local held in d8 across the call changed
callback             thread          bad iters  first wrong value
...
throw_catch          main               1/2000  1.6021944205688904E-306
...

RESULT: FAIL - callee-saved state was corrupted across a managed callback (AAPCS-VFP violation)
```

- **bad calls**: calls after which any of `d8`–`d15`, `r4`–`r11` or the stack canary differed from what was loaded before the call.
- **shifted**: calls whose `d8`–`d15` match the one-register shift exactly.
- **changed**: for each register that changed, how many calls changed it and the first wrong value seen, in hex and as a double.

The probe's patterns start with `0x4d0` followed by the register number in hex, so `0x4d08…` was loaded into `d8`, `0x4d0f…` into `d15` and `0x4d07…` into `d7`. In the example, `d9`'s first wrong value is `0x4d08…`, which is `d8`'s pattern. The first wrong `d8` values that aren't patterns (`255`, `91750.390625`) are the first exception on each thread, described under [The corruption pattern](#the-corruption-pattern).

**Exit codes:** `0` means no corruption, `1` means corruption detected, `2` means a usage or setup error.

## How this was found

[Robot Raconteur](https://github.com/robotraconteur/robotraconteur)'s .NET binding uses SWIG directors, which call C# code from native thread-pool threads. Its loopback tests segfaulted under mono on Debian sid armhf, inside Boost.Asio's scheduler (`op_queue_.pop()`), with `op_queue_` holding values like `0x43db0000` and `0x44a2d666`. Those are the floats `438.0f` and `1302.7f`, not pointers.

GCC had inlined the scheduler loop into the worker function and kept a zero constant in `d8`, which it stored on every iteration to initialise a queue on the stack. In a later run, a gdb watchpoint caught that store writing float data while `d8` held `{441.0f, 1302.7f}`. A separate check of `d8` around the director call found it `0` before the call into C# and `1362.75` (as a double) after it. The values differ because they come from different runs.

The managed code involved was a service method that throws and catches an exception internally (a generator that had been aborted). The same native library passed all tests under .NET 10, and C++, Python and Java bindings of the same library passed on the same system.

The reproducer then showed the exact one-slot shift, which pointed at code that saves and restores the FP registers as a block. Reading mono's ARM throw trampoline with that in mind turned up the hard-coded offset, and the cross-compiled A/B build confirmed it.

## Notes and limitations

- **qemu and hardware agree.** An earlier version of this test gave identical results on a Raspberry Pi (64-bit kernel, armhf userland in podman) for mono 6.8, 6.12 and 6.14.1. That covered the `d8` clobber, the same first wrong values, and .NET 10 passing. Under qemu the output is identical from run to run, on the local host and on GitHub's runners.
- **What is and isn't tested.** The test covers exceptions thrown and caught inside the callback, either directly or from a called method. It doesn't cover:
  - exceptions that escape the callback into native code, which is undefined anyway;
  - `catch` with a `when` filter;
  - async code;
  - `throw;` (rethrow), which uses the same faulty trampoline and should be affected;
  - exceptions raised by the runtime itself, such as a null dereference, which go through the corlib trampoline. Its parameter area is 8 bytes, so they should not be affected;
  - arm64. AAPCS64 also makes `d8`–`d15` callee-saved, but this probe is 32-bit only, and the bug is in 32-bit ARM code.
- **The stack is preserved in this test.** The probe's own stack canary is never corrupted here. An earlier test saw one value kept in the caller's stack frame corrupted on mono 6.8 and 6.12, but not 6.14.1. That isn't reproduced by this probe and may depend on the exact frame layout.
- **.NET details:**
  - .NET 8 does not run on Debian sid armhf at all. Its thread pool dies with SIGBUS on `ldrexd` in glibc 2.43's `pthread_cond_wait`. That is a separate .NET 8 / glibc issue, and is why the control uses .NET 10.
  - The .NET SDK doesn't run reliably under qemu-arm: MSBuild hits a stack overflow. That is why the .NET program is built on x86-64; the compiled output is portable, so only the runtime runs under emulation.
- **Debian sid changes over time.** To keep a demonstration stable, pin the image by digest with `IMAGE`. Trixie and bookworm show the same bug. For the patch verification, the cross-compiled source and the container's `mono-runtime` must be the same version, so build and test on the same day or pin both images.

## Workarounds

- Apply [the patch](patches/mono-arm-throw-fp-regs-offset.patch) and rebuild mono. On Debian, only `mono-sgen` changes.
- On armhf, run on .NET 10 or later instead of mono.
- Native code that calls managed callbacks on armhf can protect itself: call through a small trampoline that saves `d8`–`d15` before the callback and restores them afterwards. That is the same thing `probe.S` does around its callback. It is a mitigation in the caller, not a fix.

## Repository layout

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
| `.github/workflows/armhf-repro.yml` | runs the reproducer against Debian's mono packages and .NET 10 |
| `.github/workflows/mono-patch.yml` | verifies the patch: unpatched build must fail, patched build must pass |
| `results/` | reference logs from qemu on x86-64, plus the cross-compiled `loop_check` disassembly |
