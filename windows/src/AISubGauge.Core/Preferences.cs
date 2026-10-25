using Microsoft.Win32;
using System.Text.Json;

namespace AISubGauge.Core;

public interface IRunRegistry { void Set(string name, string value); void Remove(string name); }
public sealed class RunRegistry : IRunRegistry
{
    public const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public void Set(string name, string value) { using var key = Registry.CurrentUser.CreateSubKey(Key); key.SetValue(name, value); }
    public void Remove(string name) { using var key = Registry.CurrentUser.OpenSubKey(Key, true); key?.DeleteValue(name, false); }
}
public static class Startup
{
    public const string ValueName = "AISubGauge2";
    public const string MutexName = @"Local\AISubGauge2.2.0";
    public static void Apply(IRunRegistry registry, bool enabled, string executable, bool screenshot = false)
    {
        if (screenshot) return;
        if (enabled) registry.Set(ValueName, $"\"{executable}\" --autostart");
        else registry.Remove(ValueName);
    }
}
public sealed class AutostartState(IRunRegistry registry, SafeLog log)
{
    public bool Failed { get; private set; }
    public void Apply(bool enabled, string executable)
    {
        try { Startup.Apply(registry, enabled, executable); Failed = false; }
        catch { Failed = true; log.Write(LocalStatus.AutostartFailed); }
    }
}
public sealed class SettingsStore(string directory, bool readOnly = false)
{
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AISubGauge2");
    public Settings Load()
    {
        try
        {
            var path = Path.Combine(directory, "settings.json");
            LocalPathSafety.RejectReparsePoints(path);
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length > 65536) return new();
            var value = JsonSerializer.Deserialize<Settings>(stream) ?? new();
            if (!Enum.IsDefined(value.Language)) value.Language = Language.System;
            if (!Enum.IsDefined(value.Theme)) value.Theme = Theme.System;
            if (value.TrayEnabled is not { Length: 3 }) value.TrayEnabled = [true, true, true];
            return value;
        }
        catch { return new(); }
    }
    public void Save(Settings value)
    {
        if (readOnly) return;
        try
        {
            string path = Path.Combine(directory, "settings.json");
            LocalPathSafety.RejectReparsePoints(path);
            Directory.CreateDirectory(directory);
            string temporary = Path.Combine(directory, "settings." + Guid.NewGuid().ToString("N") + ".tmp");
            LocalPathSafety.RejectReparsePoints(path);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, value);
                stream.Flush(flushToDisk: true);
            }
            LocalPathSafety.RejectReparsePoints(path);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        catch { throw new IOException("Settings could not be saved."); }
    }
}
public static class SystemAppearance
{
    public static bool Light(bool taskbar = false)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue(taskbar ? "SystemUsesLightTheme" : "AppsUseLightTheme") is not int value || value != 0;
        }
        catch { return true; }
    }
}
