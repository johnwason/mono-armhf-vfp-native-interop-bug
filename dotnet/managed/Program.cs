// Native code calls a C# callback that throws and catches an exception
// internally. On Mono for 32-bit ARM the callback returns with d8-d15
// corrupted, and the native code crashes calling a completion handler whose
// address it kept in d8.

using System;
using System.Runtime.InteropServices;

static class Program
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void Callback();

    [DllImport("worker")]
    static extern int run_job(Callback cb, int iteration);

    static int handled;

    // An ordinary method that handles its own exception, such as a parser
    // falling back to a default, or a cancelled operation.
    static void OnWork()
    {
        try
        {
            throw new InvalidOperationException("handled inside the callback");
        }
        catch (InvalidOperationException)
        {
            handled++;
        }
    }

    static readonly Callback Work = OnWork;

    static int Main()
    {
        // Mono.RuntimeStructs exists only in Mono's System.Private.CoreLib
        bool mono = typeof(object).Assembly.GetType("Mono.RuntimeStructs") != null;
        Console.WriteLine("Runtime: " + RuntimeInformation.FrameworkDescription +
                          (mono ? " (Mono)" : " (CoreCLR)") + ", " + RuntimeInformation.ProcessArchitecture);

        const int calls = 1000;
        for (int i = 0; i < calls; i++)
        {
            int completed = run_job(Work, i);
            if (completed != i + 1)
            {
                Console.WriteLine("call " + i + ": " + completed + " jobs completed instead of " + (i + 1));
                return 1;
            }
        }

        Console.WriteLine("OK: " + calls + " calls, " + handled + " exceptions handled inside the callback");
        return 0;
    }
}
