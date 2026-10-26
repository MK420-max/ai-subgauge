using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace AISubGauge.UI;

internal sealed record IconLocation(string Vendor, int HResult, Rectangle? Bounds, bool InNotificationArea);
internal sealed class TrayCaptureReport
{
    public IconLocation[] Before { get; set; } = [];
    public IconLocation[] After { get; set; } = [];
    public Rectangle? OverflowBounds { get; set; }
    public string OverflowAction { get; set; } = "not-needed";
    public bool OverflowCaptured { get; set; }
    public bool OverflowClosed { get; set; }
    public string? Warning { get; set; }
}

internal interface IOverflowCloser
{
    bool IsVisible();
    Task InvokeChevronAsync();
    void Escape();
    Task SettleAsync();
}

internal static class TrayCapture
{
    // NotifyIcon does not expose its native identity publicly. These two fields are
    // pinned to the .NET 8 WindowsDesktop runtime and covered by a compatibility test.
    // Never inspect Explorer memory or other applications' notification icon data.
    internal static (IntPtr Window, uint Id) Identity(NotifyIcon icon)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var type = typeof(NotifyIcon);
        if (type.GetField("_window", flags)?.GetValue(icon) is not NativeWindow window ||
            type.GetField("_id", flags)?.GetValue(icon) is not uint id)
            throw new InvalidOperationException("Notification icon identity is unavailable.");
        return (window.Handle, id);
    }

    internal static IconLocation Locate(string vendor, int result, Rectangle bounds, Rectangle tray) =>
        new(vendor, result, result >= 0 && bounds.Width > 0 && bounds.Height > 0 ? bounds : null,
            result == 0 && bounds.Width > 0 && bounds.Height > 0 && tray.Contains(bounds));

    private static IconLocation[] Read(AppContext app, Rectangle tray) => app.NotificationIcons.Select((icon, i) =>
    {
        var identity = Identity(icon);
        var identifier = new NotifyIconIdentifier { Size = (uint)Marshal.SizeOf<NotifyIconIdentifier>(), Window = identity.Window, Id = identity.Id };
        int result = Shell_NotifyIconGetRect(ref identifier, out var rect);
        return Locate(((Core.Vendor)i).ToString(), result, rect.Rectangle, tray);
    }).ToArray();

    internal static bool Covered(IconLocation[] icons, Rectangle overflow) => icons.Length > 0 && icons.All(icon =>
        icon.InNotificationArea || (icon.HResult == 0 && icon.Bounds is Rectangle r && overflow.Contains(r)));

    internal static async Task RunAsync(AppContext app, Rectangle tray, string path, TrayCaptureReport report, Action<Rectangle, string> screenshot)
    {
        report.Before = Read(app, tray); report.After = report.Before;
        if (report.Before.All(icon => icon.InNotificationArea)) return;
        await CaptureWithCleanupAsync(async () =>
        {
            Capture.Stage = "tray-overflow-open";
            // UIA runs off the WinForms thread; no settings or registry changes.
            report.OverflowAction = VisibleOverflow().Window != IntPtr.Zero ? "already-open" : await Task.Run(OpenOverflow);
            await Task.Delay(600);
            Capture.Stage = "tray-overflow-locate";
            var flyout = VisibleOverflow();
            report.After = Read(app, tray);
            report.OverflowBounds = flyout.Bounds;
            if (flyout.Bounds is not Rectangle bounds || !Covered(report.After, bounds))
                throw new InvalidOperationException("Notification icons are not visible in the overflow flyout.");
            Capture.Stage = "tray-overflow-copy";
            DwmFlush(); screenshot(bounds, path); report.OverflowCaptured = true;
            Capture.Stage = "tray-overflow-close";
        }, new ShellOverflowCloser(), report);
    }

    // Only cleanup is best-effort. Failures to locate/copy/write images still propagate.
    internal static async Task CaptureWithCleanupAsync(Func<Task> capture, IOverflowCloser closer, TrayCaptureReport report)
    {
        try { await capture(); }
        finally { await CloseBestEffortAsync(closer, report); }
    }

    private static async Task CloseBestEffortAsync(IOverflowCloser closer, TrayCaptureReport report)
    {
        bool Visible() { try { return closer.IsVisible(); } catch { return true; } }
        if (Visible())
        {
            // Fresh UIA elements are acquired and invoked on the same MTA worker.
            // A disappearing element/provider failure must not skip the Escape fallback.
            try { await closer.InvokeChevronAsync(); await closer.SettleAsync(); } catch { }
            if (Visible())
                try { closer.Escape(); await closer.SettleAsync(); } catch { }
        }
        report.OverflowClosed = !Visible();
        report.Warning = report.OverflowClosed ? null : "Notification overflow could not be confirmed closed; PNG capture is unaffected.";
    }

    private sealed class ShellOverflowCloser : IOverflowCloser
    {
        public bool IsVisible() => VisibleOverflow().Window != IntPtr.Zero;
        public Task InvokeChevronAsync() => Task.Run(() =>
        {
            if (IsVisible()) ToggleOverflow(allowClick: false);
        });
        public Task SettleAsync() => Task.Delay(250);
        public void Escape()
        {
            var window = VisibleOverflow().Window;
            if (window == IntPtr.Zero) return;
            SetForegroundWindow(window);
            if (GetForegroundWindow() == window)
            {
                keybd_event(0x1B, 0, 0, UIntPtr.Zero);
                keybd_event(0x1B, 0, 0x0002, UIntPtr.Zero);
            }
            else
            {
                PostMessage(window, 0x100, (IntPtr)0x1B, (IntPtr)1);
                PostMessage(window, 0x101, (IntPtr)0x1B, new IntPtr(unchecked((int)0xC0000001)));
            }
        }
    }

    private static string OpenOverflow() => ToggleOverflow(allowClick: true);

    private static string ToggleOverflow(bool allowClick)
    {
        var taskbar = FindWindow("Shell_TrayWnd", null);
        if (taskbar == IntPtr.Zero) throw new InvalidOperationException("Taskbar is unavailable.");
        var root = AutomationElement.FromHandle(taskbar);
        // Class/ID selectors are locale-independent. Names support legacy English/Chinese shells.
        var condition = new OrCondition(
            new PropertyCondition(AutomationElement.ClassNameProperty, "SystemTray.ChevronIcon"),
            new PropertyCondition(AutomationElement.AutomationIdProperty, "ChevronButton"),
            new PropertyCondition(AutomationElement.NameProperty, "Show hidden icons"),
            new PropertyCondition(AutomationElement.NameProperty, "显示隐藏的图标"),
            new PropertyCondition(AutomationElement.NameProperty, "顯示隱藏的圖示"));
        var candidates = root.FindAll(TreeScope.Descendants, condition);
        foreach (AutomationElement element in candidates)
        {
            if (element.Current.IsOffscreen || !element.Current.IsEnabled) continue;
            if (element.TryGetCurrentPattern(InvokePattern.Pattern, out var pattern))
            {
                ((InvokePattern)pattern).Invoke(); return "uia-invoke";
            }
            if (!allowClick) continue;
            var rect = element.Current.BoundingRectangle;
            if (!rect.IsEmpty && rect.Width > 0 && rect.Height > 0)
            {
                Click(new Rectangle((int)rect.X, (int)rect.Y, (int)rect.Width, (int)rect.Height)); return "uia-rect-click";
            }
        }
        if (!allowClick) throw new InvalidOperationException("Hidden-icons chevron invocation is unavailable.");
        // Classic taskbar's hidden-icons chevron has control ID 1502.
        var tray = FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
        var chevron = tray == IntPtr.Zero ? IntPtr.Zero : GetDlgItem(tray, 1502);
        if (chevron != IntPtr.Zero && IsWindowVisible(chevron) && GetWindowRect(chevron, out var nativeRect))
        {
            Click(nativeRect.Rectangle); return "native-chevron-click";
        }
        throw new InvalidOperationException("Hidden-icons chevron is unavailable.");
    }

    private static void Click(Rectangle bounds)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0 || !Screen.AllScreens.Any(screen => screen.Bounds.Contains(bounds)))
            throw new InvalidOperationException("Hidden-icons chevron bounds are unavailable.");
        var previous = Cursor.Position;
        try
        {
            Cursor.Position = new(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
            mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        }
        finally { Cursor.Position = previous; }
    }

    private static (IntPtr Window, Rectangle? Bounds) VisibleOverflow()
    {
        foreach (string name in new[] { "TopLevelWindowForOverflowXamlIsland", "NotifyIconOverflowWindow" })
        {
            var window = FindWindow(name, null);
            if (window != IntPtr.Zero && IsWindowVisible(window) && GetWindowRect(window, out var rect) &&
                rect.Rectangle.Width > 0 && rect.Rectangle.Height > 0 && Screen.AllScreens.Any(screen => screen.Bounds.Contains(rect.Rectangle)))
                return (window, rect.Rectangle);
        }
        return (IntPtr.Zero, null);
    }

    [StructLayout(LayoutKind.Sequential)] private struct NotifyIconIdentifier
    {
        public uint Size; public IntPtr Window; public uint Id; public Guid Guid;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Rect
    {
        public int Left, Top, Right, Bottom;
        public readonly Rectangle Rectangle => Rectangle.FromLTRB(Left, Top, Right, Bottom);
    }
    [DllImport("shell32.dll")] private static extern int Shell_NotifyIconGetRect(ref NotifyIconIdentifier identifier, out Rect rectangle);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string name, string? title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string name, string? title);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr parent, int id);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rectangle);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
}
