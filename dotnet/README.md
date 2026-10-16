# .NET on its Mono runtime (32-bit ARM): native code crashes after a handled exception

A minimal .NET 8 example of the bug described in the [top-level README](../README.md), in .NET's own Mono runtime from dotnet/runtime. The same app, published for `linux-arm`, completes on CoreCLR and crashes on Mono (`UseMonoRuntime=true`).

- [`native/worker.c`](native/worker.c) runs a C# callback as a "job". It keeps the address of a completion handler in the callee-saved register `d8` across the job ([`native/keep_in_d8.S`](native/keep_in_d8.S)), then calls that handler. AAPCS-VFP requires the callee to preserve `d8`, and compilers do keep values there across calls. GCC did in the Boost.Asio crash that led to this report.
- [`managed/Program.cs`](managed/Program.cs) passes a callback that throws and catches an exception internally, and runs 1000 jobs.

When the callback returns, Mono has replaced `d8` with `d7` from the throw site. The native code calls a garbage address and crashes.

## Running it

On an x86-64 Linux host with podman and `qemu-user-static` registered with binfmt_misc (`F` flag):

```bash
./build.sh          # cross-compiles libworker.so and publishes out/coreclr and out/mono,
                    # all inside the .NET 8 SDK container
./run.sh coreclr    # -> OK: 1000 calls ..., exit 0
./run.sh mono       # -> SIGSEGV on the first call, non-zero exit
```

`run.sh` runs the app in a Debian bookworm armhf container. The reference output is in [`results/`](results/). On CoreCLR:

```
Runtime: .NET 8.0.32 (CoreCLR), Arm
OK: 1000 calls, 1000 exceptions handled inside the callback
```

On Mono (trimmed):

```
Runtime: .NET 8.0.32 (Mono), Arm
native: call 0: completion handler kept in d8 came back as 0x40f03000 instead of 0x40f01455; calling it
=================================================================
	Native Crash Reporting
=================================================================
Got a SIGSEGV while executing native code. This usually indicates
a fatal error in the mono runtime or one of the native libraries
used by your application.
...
	Managed Stacktrace:
=================================================================
	  at <unknown> <0xffffffff>
	  at Program:run_job <0x0003b>
	  at Program:Main <0x001eb>
```

The workflow [`.github/workflows/dotnet.yml`](../.github/workflows/dotnet.yml) builds the example and runs both. Each job passes when the outcome is the expected one: CoreCLR completes, Mono crashes after `d8` is corrupted.

## Notes

- **Why .NET 8:** it's the last release with a `linux-arm` Mono runtime pack (`Microsoft.NETCore.App.Runtime.Mono.linux-arm`, up to 8.0.x). The same code is in dotnet/runtime `main`, where Mono still serves Android `armeabi-v7a`. Android itself hasn't been tested.
- **Which runtime is which:** in the Mono build, `libcoreclr.so` is Mono, renamed so the standard .NET host can load it. The program reports which runtime it's on by checking for the Mono-only type `Mono.RuntimeStructs`.
- **Why bookworm:** .NET 8's CoreCLR doesn't start on Debian sid's glibc 2.43. That's a separate .NET 8 issue.
- **Mono's crash handler can hang.** It dumps the memory around the faulting instruction without checking that the memory is mapped. When it isn't, the dump faults again inside the handler and the process never exits. Under qemu this varies from run to run, so `run.sh` stops the program after 120 seconds (`TIMEOUT`) and returns exit code 124. Either way, the `native:` line has already shown that `d8` was corrupted.
- **Crash vs. silent corruption:** what `d8` receives depends on the build. A function pointer is used here so the failure is always a crash. With a data pointer instead, one build got `NULL` and crashed, and another got a valid address and silently read the wrong value (`7968` instead of `42`).
