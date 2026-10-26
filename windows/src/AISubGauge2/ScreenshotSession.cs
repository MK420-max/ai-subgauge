using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AISubGauge.UI;

public interface IScreenshotLockProbe { bool IsUnlockedDefaultDesktop(); }
public sealed class SessionLockedException : Exception { }

public static class ScreenshotSession
{
    public const string LockedMessage = "Session is locked; no screenshots taken.";
    public const int LockedExitCode = 3;
    private static readonly IScreenshotLockProbe NativeProbe = new WindowsScreenshotLockProbe();

    public static void EnsureUnlocked(IScreenshotLockProbe? probe = null)
    {
        try { if ((probe ?? NativeProbe).IsUnlockedDefaultDesktop()) return; }
        catch { /* Unknown session state fails closed. */ }
        throw new SessionLockedException();
    }

    // Gate startup before any windows, providers, tray icons or capture callbacks are created.
    public static bool TryStart(string directory, Action start, IScreenshotLockProbe? probe = null)
    {
        try { EnsureUnlocked(probe); }
        catch (SessionLockedException) { WriteLockedFailure(directory); return false; }
        start(); return true;
    }

    public static void WriteLockedFailure(string directory)
    {
        try { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "capture-failed.txt"), LockedMessage); }
        catch { /* Preserve the fixed exit status even when evidence cannot be written. */ }
    }
}

internal sealed class WindowsScreenshotLockProbe : IScreenshotLockProbe
{
    public bool IsUnlockedDefaultDesktop()
    {
        IntPtr desktop = OpenInputDesktop(0, false, 0x0001); // DESKTOP_READOBJECTS
        if (desktop == IntPtr.Zero) return false;
        try
        {
            var name = new StringBuilder(256);
            if (!GetUserObjectInformation(desktop, 2, name, name.Capacity * sizeof(char), out _) ||
                !string.Equals(name.ToString(), "Default", StringComparison.Ordinal)) return false; // UOI_NAME
            using var process = Process.GetCurrentProcess();
            IntPtr buffer = IntPtr.Zero;
            try
            {
                if (!WTSQuerySessionInformation(IntPtr.Zero, process.SessionId, 25, out buffer, out uint bytes) ||
                    buffer == IntPtr.Zero || bytes < Marshal.SizeOf<SessionInfoExHeader>()) return false; // WTSSessionInfoEx
                var info = Marshal.PtrToStructure<SessionInfoExHeader>(buffer);
                return info.Level == 1 && info.SessionId == process.SessionId &&
                    info.SessionState == 0 && info.SessionFlags == 1; // WTSActive, WTS_SESSIONSTATE_UNLOCK
            }
            finally { if (buffer != IntPtr.Zero) WTSFreeMemory(buffer); }
        }
        finally { CloseDesktop(desktop); }
    }

    // WTSINFOEXW prefix only: its Level1 union has 8-byte alignment (contains LARGE_INTEGER).
    // Do not marshal the trailing user/domain strings; only state is needed. Windows 10+.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct SessionInfoExHeader
    {
        [FieldOffset(0)] public uint Level;
        [FieldOffset(8)] public int SessionId;
        [FieldOffset(12)] public int SessionState;
        [FieldOffset(16)] public int SessionFlags;
    }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetUserObjectInformationW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder value, int length, out int needed);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WTSQuerySessionInformation(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out uint bytes);
    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr buffer);
}
