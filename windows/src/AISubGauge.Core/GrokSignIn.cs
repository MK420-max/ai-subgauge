using System.Diagnostics;

namespace AISubGauge.Core;

public sealed class GrokSignIn(Func<Task<VerifiedExecutable>>? resolve = null,
    Func<ProcessStartInfo, Task>? run = null)
{
    private int running;
    public bool Running => Volatile.Read(ref running) != 0;

    public async Task<bool> RunAsync()
    {
        if (Interlocked.CompareExchange(ref running, 1, 0) != 0) return false;
        try
        {
            using var executable = await (resolve?.Invoke() ?? Executables.OpenAsync("grok")).ConfigureAwait(false);
            var info = new ProcessStartInfo(executable.Path)
            {
                UseShellExecute = false, CreateNoWindow = false,
                WorkingDirectory = Path.GetDirectoryName(executable.Path)!
            };
            info.ArgumentList.Add("login");
            // AISubGauge2 is a WinExe with no attached console. Windows creates the console
            // for this console child; do not hide the window or redirect its interactive I/O.
            await (run?.Invoke(info) ?? RunProcessAsync(info)).ConfigureAwait(false);
            return true;
        }
        finally { Volatile.Write(ref running, 0); }
    }

    private static async Task RunProcessAsync(ProcessStartInfo info)
    {
        using var process = Process.Start(info) ?? throw new SafeFailure(Fault.Network);
        await process.WaitForExitAsync().ConfigureAwait(false);
        // Even a cancelled/failed login must re-poll: the CLI owns the resulting auth state.
    }
}
