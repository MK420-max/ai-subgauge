using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AISubGauge.Providers;

namespace AISubGauge;

internal static class StatusReport
{
    public static async Task<int> SaveAsync(string? path, bool demo)
    {
        AppSettings settings = demo ? AppSettings.ForDemo() : AppSettings.Load(migrate: false);
        // No settings filter: the report includes every registered provider, even hidden ones.
        var entries = await Task.WhenAll(ProviderRegistry.CreateEnabled().Select(async provider =>
        {
            bool signedIn = !demo && ProviderRegistry.IsSignedInLocally(provider);
            QuotaSnapshot snapshot = await QuotaService.ReadProviderAsync(provider, demo, CancellationToken.None, settings.HasConsent(provider.Id)).ConfigureAwait(false);
            return CreateEntry(provider.Id, signedIn, settings.HasConsent(provider.Id), snapshot);
        })).ConfigureAwait(false);
        string json = JsonSerializer.Serialize(entries, new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        });
        if (path is null)
        {
            OpenConsoleOutput();
            Console.Out.WriteLine(json);
        }
        else
        {
            await using FileStream file = LocalFiles.CreateStatusFile(path);
            byte[] bytes = new UTF8Encoding(false).GetBytes(json + Environment.NewLine);
            await file.WriteAsync(bytes).ConfigureAwait(false);
        }
        return 0;
    }

    internal static object CreateEntry(string id, bool signedIn, bool consent, QuotaSnapshot snapshot)
    {
        bool realData = !snapshot.IsDemo && snapshot.Error is null && snapshot.Windows.Count > 0;
        return new
        {
            id, consent, isSignedInLocally = signedIn, isRealData = realData,
            isDemo = snapshot.IsDemo, isStale = snapshot.IsStale,
            updatedAt = realData ? (DateTime?)snapshot.UpdatedAt : null,
            remainingPercent = realData ? snapshot.RemainingPercent : null,
            error = snapshot.Error is null ? null : Diagnostics.Redact(snapshot.Error)
        };
    }

    public static void WriteJson(object value)
    {
        OpenConsoleOutput();
        Console.Out.WriteLine(JsonSerializer.Serialize(value));
    }

    public static void WriteError(string message)
    {
        try
        {
            OpenConsoleOutput();
            Console.Out.WriteLine(JsonSerializer.Serialize(new { error = message }));
        }
        catch (Exception) { } // No UI fallback in headless mode.
    }

    private static void OpenConsoleOutput()
    {
        IntPtr handle = GetStdHandle(-11); // STD_OUTPUT_HANDLE; preserve inherited pipes/files.
        if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            AttachConsole(uint.MaxValue); // Attach to the parent console without opening a window.
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);
}
