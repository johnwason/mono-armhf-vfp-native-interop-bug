# Mono on 32-bit ARM corrupts callee-saved VFP registers after a caught exception in a native-to-managed callback

On 32-bit ARM Linux, when native code calls a managed callback through a delegate (reverse P/Invoke) and that callback throws **and catches** an exception, the Mono runtime returns to the native caller with the callee-saved VFP registers `d8`–`d15` corrupted.

The ARM procedure call standard (AAPCS / AAPCS-VFP) requires a callee to preserve `d8`–`d15`, the same as `r4`–`r11`, and compiled native code relies on this. A value the caller keeps in one of them across the call is silently replaced. The result is wrong data or a crash in native code that has nothing to do with the exception.

**Cause:** Mono's ARM throw trampoline passes the saved floating-point registers to the exception handler through a pointer that is 8 bytes too low. The catch handler resumes with every VFP register holding its lower neighbour's value. The bug is a hard-coded offset in `mono/mini/exceptions-arm.c`, introduced in mono 6.0 (2019). See [Root cause and fix](#root-cause-and-fix).

| Runtime | Result |
|---|---|
| mono 6.8.0.105, 6.12.0.199, 6.14.1 (Debian bookworm, trixie, sid) | **corrupted**, every call that catches an exception |
| mono 6.14.1 built from Debian's source, unmodified | **corrupted**, same as the package |
| mono 6.14.1 built from Debian's source, [with the fix](mono/patches/mono-arm-throw-fp-regs-offset.patch) | correct |
| .NET 8 on its Mono runtime (`UseMonoRuntime=true`, linux-arm) | **corrupted**: the example's native code crashes |
| .NET 8 and .NET 10 on CoreCLR, linux-arm | correct |

Callbacks that don't throw are not affected, and neither are the integer callee-saved registers `r4`–`r11`. Exceptions raised by the JIT's own checks, such as an array bounds or null check, go through a different trampoline and are not affected either.

## Test cases

Each folder is self-contained, has its own README, and runs on an x86-64 Linux host with podman and qemu-user. No ARM hardware is needed: the code is cross-compiled and run in Debian armhf containers. Each has a GitHub Actions workflow that **passes when the results are as expected**: the affected runtimes show the bug and the others don't.

| Folder | What it tests | Workflow |
|---|---|---|
| [`mono/`](mono/) | Classic mono, as packaged by Debian. An assembly probe measures exactly which registers change across a callback. Also builds mono from Debian's source with and without the fix and compares them. .NET 10 on CoreCLR is the control. | [`mono.yml`](.github/workflows/mono.yml) |
| [`dotnet/`](dotnet/) | .NET's own Mono runtime (dotnet/runtime). A .NET 8 app published for linux-arm on Mono crashes; the same app on CoreCLR completes. | [`dotnet.yml`](.github/workflows/dotnet.yml) |

## Root cause and fix

The bug is in `get_throw_trampoline ()` in [`mono/mini/exceptions-arm.c`](https://github.com/mono/mono/blob/main/mono/mini/exceptions-arm.c#L224-L298). The line numbers below are from mono 6.14.1, which matches mono/mono `main`, WineHQ's `main` and dotnet/runtime's `src/mono/mono/mini/exceptions-arm.c`. In 6.12.0.199 the trampoline is at the same lines, and in 6.8.0.105 one line earlier.

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

`mono_arm_throw_exception ()` copies 16 doubles from that pointer into `ctx.fregs` (L168), so `fregs[0]` is padding and `fregs[n]` is the saved `d(n-1)`. On Linux the unwinder doesn't touch `fregs[8..15]` (that code is `#ifdef TARGET_IOS`, L494–515). `restore_context` then reloads all 16 registers from `ctx.fregs` (L72–73) before jumping to the catch handler, so every VFP register comes back as its lower neighbour. A `throw;` inside a `catch` passes through the trampoline again and shifts them by two.

The integer registers survive because their pointer is computed from `cfa_offset` (L287), not hard-coded. Exceptions raised by JIT checks use the corlib trampoline, whose parameter area really is 8 bytes. On Linux/ARM outside Android, mono also compiles null checks as explicit checks (`MONO_ARCH_DISABLE_HW_TRAPS`), so a `NullReferenceException` takes that path too.

Mono's own code never notices: on armhf the JIT never allocates `d8`–`d15` ([`mini-arm.h`](https://github.com/mono/mono/blob/main/mono/mini/mini-arm.h#L68-L82)). Its only use of them is `d14`/`d15` as scratch, which it saves and restores around each use (`mono_arm_emit_vfp_scratch_save`/`_restore` in `mini-arm.c`). Nothing in managed code puts the corrupted values back, so they pass straight through to the native caller when the callback returns.

The hard-coded `8` is only correct when the parameter area is 8 bytes, as it was before mono 6.0 and still is for the corlib and resume-unwind trampolines. The fix is to use the computed size, in both branches:

```diff
-		ARM_ADD_REG_IMM8 (code, ARMREG_LR, ARMREG_SP, 8);
+		ARM_ADD_REG_IMM8 (code, ARMREG_LR, ARMREG_SP, param_size);
```

The full patch with a description is [`mono/patches/mono-arm-throw-fp-regs-offset.patch`](mono/patches/mono-arm-throw-fp-regs-offset.patch). It applies with `patch -p1` to Debian's mono 6.14.1 source and to mono `main`. For dotnet/runtime the same change applies to `src/mono/mono/mini/exceptions-arm.c`.

### Scope

- **Classic mono 6.0 and later** on 32-bit ARM with VFP. Mono 5.20 reserved a fixed 8-byte parameter area here and is not affected.
- **.NET's Mono runtime** on 32-bit ARM: measured on linux-arm with .NET 8, the last release with a linux-arm Mono runtime pack. In current .NET this mainly means **Android `armeabi-v7a`**. Android hasn't been tested. The faulty branch runs whenever VFP is present, not only with the hard-float ABI, so softfp targets are expected to be affected too.
- **Not affected:** CoreCLR, .NET Framework, 64-bit ARM (different code), and 32-bit ARM without VFP.
- **A separate gap, not tested:** on Linux/ARM, `mono-sigcontext.h` doesn't define `UCONTEXT_REG_VFPREGS`, so exceptions raised from a signal never get the FP registers from the signal context. With hardware traps disabled this doesn't seem reachable from JIT code on Linux, but it might be on Android.

## How this was found

[Robot Raconteur](https://github.com/robotraconteur/robotraconteur)'s .NET binding uses SWIG directors, which call C# code from native thread-pool threads. Its loopback tests segfaulted under mono on Debian sid armhf, inside Boost.Asio's scheduler (`op_queue_.pop()`), with `op_queue_` holding values like `0x43db0000` and `0x44a2d666`. Those are the floats `438.0f` and `1302.7f`, not pointers.

GCC had inlined the scheduler loop into the worker function and kept a zero constant in `d8`, which it stored on every iteration to initialise a queue on the stack. In a later run, a gdb watchpoint caught that store writing float data while `d8` held `{441.0f, 1302.7f}`. A separate check of `d8` around the director call found it `0` before the call into C# and `1362.75` (as a double) after it. The values differ because they come from different runs.

The managed code involved was a service method that throws and catches an exception internally (a generator that had been aborted). The same native library passed all tests under .NET 10, and C++, Python and Java bindings of the same library passed on the same system.

The probe in [`mono/`](mono/) then showed the exact one-slot shift. That pointed at code that saves and restores the FP registers as a block, and reading mono's ARM throw trampoline with that in mind turned up the hard-coded offset. A cross-compiled A/B build confirmed it.

## Workarounds

- Apply [the patch](mono/patches/mono-arm-throw-fp-regs-offset.patch) and rebuild mono. On Debian, only `mono-sgen` changes.
- On Linux armhf, run on .NET 10 or later (CoreCLR) instead of mono.
- Native code that calls managed callbacks on 32-bit ARM can protect itself: call through a small trampoline that saves `d8`–`d15` before the callback and restores them afterwards. That is what [`mono/native/probe.S`](mono/native/probe.S) does around its callback. It is a mitigation in the caller, not a fix.
