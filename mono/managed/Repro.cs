// Managed side of the reproducer. The same source is compiled two ways:
//   mono:    mcs -out:Repro.exe Repro.cs
//   .NET 10: dotnet build Repro.csproj      (defines NET, see #if below)
//
// Usage: Repro [iterations]       (default 2000)
// Exit code: 0 = no corruption detected, 1 = corruption detected, 2 = setup error.

using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

static class Repro
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void Callback();

    const int Slots = 17;

    [DllImport("native")] static extern int probe_run(Callback cb, int n, [Out] int[] counts, [Out] ulong[] first, out int shifted);
    [DllImport("native")] static extern int probe_run_on_thread(Callback cb, int n, [Out] int[] counts, [Out] ulong[] first, out int shifted);
    [DllImport("native")] static extern int loop_check(Callback cb, int n, out double firstBad);
    [DllImport("native")] static extern int loop_check_on_thread(Callback cb, int n, out double firstBad);

    static readonly string[] SlotNames = {
        "d8", "d9", "d10", "d11", "d12", "d13", "d14", "d15",
        "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11",
        "stack"
    };

    // ---- callbacks invoked from native code ----

    static int sink;

    static void Plain() { sink++; }

    static void TryFinally()
    {
        try { sink++; }
        finally { sink--; }
    }

    static void ThrowCatch()
    {
        try { throw new InvalidOperationException("x"); }
        catch (InvalidOperationException) { }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void Thrower() { throw new InvalidOperationException("x"); }

    static void ThrowCatchNested()
    {
        try { Thrower(); }
        catch (InvalidOperationException) { }
    }

    // throw; inside a catch, caught by an outer handler: two passes through
    // mono's throw/rethrow trampoline
    static void Rethrow()
    {
        try
        {
            try { throw new InvalidOperationException("x"); }
            catch (InvalidOperationException) { throw; }
        }
        catch (InvalidOperationException) { }
    }

    // An exception raised by a JIT check (array bounds), which mono throws
    // through a different trampoline (control)
    static int[] smallArray = new int[1];
    static int badIndex = 5;

    static void IndexOutOfRange()
    {
        try { sink += smallArray[badIndex]; }
        catch (IndexOutOfRangeException) { }
    }

    // Kept in static fields so the delegates (and their native thunks) live
    // for the whole run.
    static readonly Callback[] Callbacks = { Plain, TryFinally, IndexOutOfRange, ThrowCatch, ThrowCatchNested, Rethrow };
    static readonly string[] CallbackNames = { "plain", "try_finally", "index_oob", "throw_catch", "throw_catch_nested", "rethrow" };

    static string RuntimeName()
    {
#if NET
        return RuntimeInformation.FrameworkDescription + " (" + RuntimeInformation.ProcessArchitecture + ")";
#else
        Type mono = Type.GetType("Mono.Runtime");
        if (mono != null)
        {
            var m = mono.GetMethod("GetDisplayName", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
            if (m != null)
                return "Mono " + m.Invoke(null, null);
        }
        return "CLR " + Environment.Version;
#endif
    }

    static int Main(string[] args)
    {
        int n = 2000;
        if (args.Length > 0 && !int.TryParse(args[0], out n))
        {
            Console.Error.WriteLine("usage: Repro [iterations]");
            return 2;
        }

        Console.WriteLine("Runtime:    " + RuntimeName());
        Console.WriteLine("OS:         " + Environment.OSVersion);
        Console.WriteLine("Iterations: " + n + " per row");
        Console.WriteLine();

        bool anyBad = false;

        Console.WriteLine("Exact probe: calls in which a callee-saved register or the caller's stack slot changed");
        Console.WriteLine("  'shifted' = calls where d8-d15 came back as the caller's d7-d14, i.e. moved up one register");
        Console.WriteLine("{0,-20} {1,-14} {2,10} {3,10}  {4}", "callback", "thread", "bad calls", "shifted", "changed (calls, first value seen)");
        for (int c = 0; c < Callbacks.Length; c++)
        {
            for (int t = 0; t < 2; t++)
            {
                var counts = new int[Slots];
                var first = new ulong[Slots];
                int shifted;
                int bad = t == 0
                    ? probe_run(Callbacks[c], n, counts, first, out shifted)
                    : probe_run_on_thread(Callbacks[c], n, counts, first, out shifted);
                if (bad < 0)
                {
                    Console.Error.WriteLine("pthread_create failed");
                    return 2;
                }
                if (bad > 0)
                    anyBad = true;

                string detail = "";
                for (int s = 0; s < Slots; s++)
                {
                    if (counts[s] == 0)
                        continue;
                    string v = s < 8
                        ? "0x" + first[s].ToString("x16") + " = " + BitConverter.Int64BitsToDouble((long)first[s]).ToString("R")
                        : "0x" + first[s].ToString(s == 16 ? "x16" : "x8");
                    detail += string.Format("{0}({1}, {2}) ", SlotNames[s], counts[s], v);
                }
                Console.WriteLine("{0,-20} {1,-14} {2,10} {3,10}  {4}",
                    CallbackNames[c], t == 0 ? "main" : "native pthread", bad + "/" + n, shifted + "/" + n, detail.Length == 0 ? "-" : detail);
            }
        }
        Console.WriteLine();

        Console.WriteLine("Compiler-generated loop: iterations in which a C local held in d8 across the call changed");
        Console.WriteLine("  (with the shift above, d8 gets whatever the caller left in d7, so this count depends on");
        Console.WriteLine("   the compiled code: after the first miss this loop happens to leave the right value in d7)");
        Console.WriteLine("{0,-20} {1,-14} {2,10}  {3}", "callback", "thread", "bad iters", "first wrong value");
        for (int c = 0; c < Callbacks.Length; c++)
        {
            for (int t = 0; t < 2; t++)
            {
                double fb;
                int bad = t == 0
                    ? loop_check(Callbacks[c], n, out fb)
                    : loop_check_on_thread(Callbacks[c], n, out fb);
                if (bad < 0)
                {
                    Console.Error.WriteLine("pthread_create failed");
                    return 2;
                }
                if (bad > 0)
                    anyBad = true;
                Console.WriteLine("{0,-20} {1,-14} {2,10}  {3}",
                    CallbackNames[c], t == 0 ? "main" : "native pthread", bad + "/" + n, bad > 0 ? fb.ToString("R") : "-");
            }
        }
        Console.WriteLine();

        Console.WriteLine(anyBad
            ? "RESULT: FAIL - callee-saved state was corrupted across a managed callback (AAPCS-VFP violation)"
            : "RESULT: PASS - callee-saved state preserved");
        return anyBad ? 1 : 0;
    }
}
