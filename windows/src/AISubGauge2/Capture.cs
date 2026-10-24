using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace AISubGauge.UI;

public static class Capture
{
    public static string Stage { get; set; } = "initialization";
    public static async Task RunAsync(AppContext app, PanelForm panel, SettingsForm settings, Options options)
    {
        ScreenshotSession.EnsureUnlocked();
        string directory = options.ScreenshotDirectory!; Directory.CreateDirectory(directory);
        string suffix = (options.Theme == Core.Theme.Dark ? "dark" : "light") + "-" + (options.Language == Core.Language.Chinese ? "zh" : "en");
        string FileName(string name) => Path.Combine(directory, name + "-" + suffix + ".png");
        // These are visible top-level windows. Never substitute DrawToBitmap for the screen capture.
        Stage = "panel"; panel.OpenNearTray(); Stage = "panel-settle"; await Settle(panel); Stage = "panel-copy"; ScreenShot(panel.Bounds, FileName("panel")); panel.Hide();
        Stage = "settings"; app.OpenSettings(); settings.SelectPage(false); await Settle(settings); ScreenShot(settings.Bounds, FileName("settings-subs"));
        settings.SelectPage(true); await Settle(settings); ScreenShot(settings.Bounds, FileName("settings-general")); settings.Hide();
        await Task.Delay(500);
        Stage = "tray"; var tray = TrayBounds(); ScreenShot(tray, FileName("tray-area"));
        ScreenshotSession.EnsureUnlocked();
        foreach (bool showPercentage in new[] { false, true })
        {
            SaveTrayIconPreview(FileName(showPercentage ? "tray-icon-percent" : "tray-icon"), app.Snapshots, app.TrayDark, app.TrayIconSize, showPercentage);
            var families = app.Snapshots.Select(data => new TrayIconFamily(data.Vendor,
                data.FiveHour.Percent ?? data.Weekly.Percent, app.TrayDark, showPercentage)).ToArray();
            SaveTrayIconFiles(directory, suffix, families, app.TrayDark, showPercentage);
        }
        var trayReport = new TrayCaptureReport();
        bool complete = false;
        try
        {
            await TrayCapture.RunAsync(app, tray, FileName("tray-overflow"), trayReport, ScreenShot);
            complete = true;
        }
        finally
        {
            File.WriteAllText(Path.Combine(directory, "capture-" + suffix + ".json"), JsonSerializer.Serialize(new
            {
                mode = app.Demo ? "demo" : "live", screenCapture = "Graphics.CopyFromScreen",
                trayPolicy = "Locate our icons with Shell_NotifyIconGetRect; open overflow only when needed; close via UIA chevron then Escape. Close failure is a warning. No notification settings changed.",
                trayTheme = app.TrayDark ? "dark" : "light", trayIconSize = app.TrayIconSize,
                showTrayPercentage = app.Settings.ShowTrayPercentage,
                settingsWritten = false, autostartWritten = false, theme = options.Theme.ToString(), language = options.Language.ToString(),
                trayBounds = new { tray.X, tray.Y, tray.Width, tray.Height }, trayIcons = trayReport,
                complete, recordedUtc = DateTimeOffset.UtcNow
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
    }
    internal static void SaveTrayIconPreview(string path, IReadOnlyList<Core.Snapshot> snapshots, bool dark, int size, bool showPercentage = false)
    {
        using var icons = new Bitmap(480, 160); using (var graphics = Graphics.FromImage(icons))
        {
            graphics.Clear(dark ? Color.FromArgb(28, 28, 32) : Color.FromArgb(246, 246, 248));
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor; graphics.PixelOffsetMode = PixelOffsetMode.Half;
            for (int i = 0; i < 3; i++)
            {
                var data = snapshots[i]; using var source = RingIcon.TrayBitmap(data.Vendor, data.FiveHour.Percent ?? data.Weekly.Percent, dark, size, showPercentage);
                graphics.DrawImage(source, new Rectangle(i * 160, 0, 160, 160), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel);
            }
        }
        icons.Save(path, ImageFormat.Png);
    }
    internal static void SaveTrayIconFiles(string directory, string suffix, IReadOnlyList<TrayIconFamily> families, bool dark, bool showPercentage = false)
    {
        // A Windows ICO represents one vendor at seven resolutions. The unsuffixed file is Codex;
        // save the other two alongside it rather than mixing vendors into a single ICO directory.
        if (showPercentage) suffix = "percent-" + suffix;
        families[0].Save(Path.Combine(directory, "tray-icon-" + suffix + ".ico"));
        families[1].Save(Path.Combine(directory, "tray-icon-claude-" + suffix + ".ico"));
        families[2].Save(Path.Combine(directory, "tray-icon-grok-" + suffix + ".ico"));
        TrayIconFamily.SaveContactSheet(Path.Combine(directory, "tray-icon-sizes-" + suffix + ".png"),
            [("Codex", families[0]), ("Claude", families[1]), ("Grok", families[2])], dark);
    }
    private static async Task Settle(Form form)
    {
        form.TopMost = true; form.Show(); form.BringToFront(); form.Activate(); form.Refresh();
        await Task.Delay(650); DwmFlush();
        if (!form.Visible) throw new CaptureHiddenException(); if (form.WindowState == FormWindowState.Minimized) throw new CaptureMinimizedException();
    }
    private sealed class CaptureHiddenException : Exception { }
    private sealed class CaptureMinimizedException : Exception { }
    private static void ScreenShot(Rectangle rectangle, string path)
    {
        ScreenshotSession.EnsureUnlocked();
        using var bitmap = new Bitmap(rectangle.Width, rectangle.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(rectangle.Location, Point.Empty, rectangle.Size, CopyPixelOperation.SourceCopy);
        bitmap.Save(path, ImageFormat.Png);
    }
    private static Rectangle TrayBounds()
    {
        IntPtr taskbar = FindWindow("Shell_TrayWnd", null);
        IntPtr tray = FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
        if (tray != IntPtr.Zero && GetWindowRect(tray, out var rect) && rect.Right > rect.Left && rect.Bottom > rect.Top) return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        var screen = Screen.PrimaryScreen!.Bounds;
        return new(screen.Right - Math.Min(520, screen.Width), screen.Bottom - Math.Min(80, screen.Height), Math.Min(520, screen.Width), Math.Min(80, screen.Height));
    }
    public static void WriteFailure(Options options, Exception? error = null)
    {
        if (error is SessionLockedException)
        {
            Environment.ExitCode = ScreenshotSession.LockedExitCode;
            ScreenshotSession.WriteLockedFailure(options.ScreenshotDirectory!); return;
        }
        try { Directory.CreateDirectory(options.ScreenshotDirectory!); File.WriteAllText(Path.Combine(options.ScreenshotDirectory!, "capture-failed.txt"), new Core.Redactor().Clean($"Screen capture failed. Stage: {Stage}. Error type: {error?.GetType().Name ?? "Unknown"}. Native code: {(error as System.ComponentModel.Win32Exception)?.NativeErrorCode}. No exception message was recorded.")); } catch { }
    }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string name, string? title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string name, string? title);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rectangle);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
}





