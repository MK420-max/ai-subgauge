using AISubGauge.Core;
using AISubGauge.UI;
using System.Globalization;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Contains("--export-icons", StringComparer.Ordinal))
        {
            // Offline renderer only: before GUI, singleton, settings, providers or desktop access.
            VerificationConsole.Connect();
            try
            {
                if (args.Length != 2 || args[0] != "--export-icons" || string.IsNullOrWhiteSpace(args[1]))
                { Console.WriteLine("Usage: AISubGauge2 --export-icons <directory>"); Environment.ExitCode = 2; return; }
                IconExport.Save(args[1]);
                Console.WriteLine("Icon export complete: native PNGs, 8x PNGs, ICOs and mac-compare sheets.");
            }
            catch { Console.WriteLine("Icon export failed."); Environment.ExitCode = 1; }
            finally { Logos.DisposeAll(); }
            return;
        }
        if (args.Contains("--verify-codex", StringComparer.Ordinal))
        {
            // Handle before WinForms initialization, singleton activation, providers or registry writes.
            VerificationConsole.Connect();
            Environment.ExitCode = CodexVerificationCommand.Run(() =>
            {
                if (args.Length != 1) throw new SafeFailure(Fault.VerificationFailed);
                var settings = new SettingsStore(SettingsStore.DefaultDirectory, readOnly: true).Load();
                return Executables.Open("codex", settings.AllowUnsignedCodexNpm);
            }, Console.Out);
            return;
        }
        ApplicationConfiguration.Initialize();
        var texts = new Texts(Presentation.ResolveLanguage(Language.System, CultureInfo.CurrentUICulture));
        Options options;
        try { options = Options.Parse(args); }
        catch { MessageBox.Show(texts["InvalidArguments"], texts["AppTitle"]); Environment.ExitCode = 2; return; }
        if (options.ScreenshotDirectory is { } directory)
        {
            if (!ScreenshotSession.TryStart(directory, () => RunApplication(options, texts)))
                Environment.ExitCode = ScreenshotSession.LockedExitCode;
        }
        else RunApplication(options, texts);
    }
    private static void RunApplication(Options options, Texts texts)
    {
        using var mutex = new Mutex(true, Startup.MutexName, out bool first);
        if (!first)
        {
            try { using var signal = EventWaitHandle.OpenExisting(@"Local\AISubGauge2.Activate"); signal.Set(); } catch { }
            Environment.ExitCode = options.ScreenshotDirectory is null ? 0 : 3; return;
        }
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, eventArgs) => { Environment.ExitCode = 1; if (options.ScreenshotDirectory is not null) Capture.WriteFailure(options, eventArgs.Exception); Application.Exit(); };
        try { using var app = new AISubGauge.UI.AppContext(options); Application.Run(app); }
        catch (Exception error) { Environment.ExitCode = 1; if (options.ScreenshotDirectory is not null) Capture.WriteFailure(options, error); else MessageBox.Show(texts["StartupFailed"], texts["AppTitle"]); }
        finally { mutex.ReleaseMutex(); }
    }
}

internal static class VerificationConsole
{
    public static void Connect()
    {
        // Preserve redirected stdout; otherwise attach to the invoking console without creating a GUI.
        IntPtr output = GetStdHandle(-11);
        if (output == IntPtr.Zero || output == new IntPtr(-1)) AttachConsole(uint.MaxValue);
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true });
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int handle);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);
}


