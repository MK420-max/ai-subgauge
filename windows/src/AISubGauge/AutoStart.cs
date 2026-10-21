using System;
using System.IO;
using Microsoft.Win32;

namespace AISubGauge;

internal sealed class AutoStart
{
    internal const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private readonly RegistryKey _key;
    private readonly string _name;
    private readonly string _legacyName;
    private readonly string _installationRoot;
    private readonly string? _trustedAncestor;
    public bool LegacyRemoved { get; private set; }

    // Tests pass a disposable HKCU subkey and separate value names.
    public AutoStart(RegistryKey key, string name = "AISubGauge", string legacyName = "WindowsQuotaTray", string? installationRoot = null,
        string? trustedAncestor = null)
    {
        _key = key; _name = name; _legacyName = legacyName;
        _installationRoot = installationRoot ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "AISubGauge");
        _trustedAncestor = trustedAncestor;
    }

    public string? Command
    {
        get
        {
            string? command = _key.GetValue(_name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
            if (!string.IsNullOrWhiteSpace(command)) return command;
            return _key.GetValue(_legacyName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string legacy &&
                IsLegacyCommand(legacy) ? legacy : command;
        }
    }
    public bool Enabled => !string.IsNullOrWhiteSpace(Command);

    public void Apply(bool enabled, string executable)
    {
        if (enabled)
        {
            try
            {
                LocalFiles.WithProtectedExecutable(executable, _installationRoot,
                    () => _key.SetValue(_name, Quote(executable), RegistryValueKind.String), _trustedAncestor);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Failed installation checks must not leave our older unsafe startup targets active.
                // Only inspect our two known value names and recognize exact executable commands.
                RemoveLegacy();
                if (Command is string command && (IsCommandFor(command, "AISubGauge.exe") || IsLegacyCommand(command)))
                    _key.DeleteValue(_name, throwOnMissingValue: false);
                throw;
            }
        }
        else
        {
            RemoveLegacy();
            _key.DeleteValue(_name, throwOnMissingValue: false);
        }
    }

    public void Migrate(string executable)
    {
        object? legacy = _key.GetValue(_legacyName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
        // Only remove an old entry whose command actually names our previous executable.
        if (legacy is not string command || !IsLegacyCommand(command)) return;
        Apply(true, executable);
        RemoveLegacy();
    }

    private void RemoveLegacy()
    {
        if (_key.GetValue(_legacyName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not string command ||
            !IsLegacyCommand(command)) return;
        _key.DeleteValue(_legacyName, throwOnMissingValue: false);
        LegacyRemoved = true;
    }

    internal static bool IsLegacyCommand(string command) => IsCommandFor(command, "WindowsQuotaTray.exe");

    private static bool IsCommandFor(string command, string name)
    {
        string text = command.Trim();
        string executable;
        if (text.StartsWith('"'))
        {
            int end = text.IndexOf('"', 1);
            if (end < 0 || !string.IsNullOrWhiteSpace(text[(end + 1)..])) return false;
            executable = text[1..end];
        }
        else executable = text;
        return Path.IsPathFullyQualified(executable) &&
            Path.GetFileName(executable).Equals(name, StringComparison.OrdinalIgnoreCase);
    }

    private static string Quote(string executable) => "\"" + LocalFiles.FullPath(executable) + "\"";

    public static void Initialize(AppSettings settings)
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunPath);
        var auto = new AutoStart(key);
        string executable = Environment.ProcessPath ?? throw new InvalidOperationException();
        Initialize(settings, auto, executable);
    }

    internal static void Initialize(AppSettings settings, AutoStart auto, string executable)
    {
        try
        {
            bool enabled = settings.LaunchAtLogin ?? true;
            if (enabled) auto.Migrate(executable);
            auto.Apply(enabled, executable);
            if (settings.LaunchAtLogin is null) { settings.LaunchAtLogin = true; settings.Save(); }
        }
        catch (IOException)
        {
            // A portable/unprotected copy can still run, but must not persist itself at login.
            settings.LaunchAtLogin = false;
            settings.Save();
        }
        catch (UnauthorizedAccessException) { settings.LaunchAtLogin = false; }
    }

    public static int RunCommand(string action)
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunPath);
        var auto = new AutoStart(key);
        string executable = Environment.ProcessPath ?? throw new InvalidOperationException();
        StatusReport.WriteJson(RunCommand(action, auto, executable));
        return 0;
    }

    internal static object RunCommand(string action, AutoStart auto, string executable)
    {
        if (action == "on") auto.Migrate(executable);
        if (action != "status")
        {
            bool enabled = action == "on";
            auto.Apply(enabled, executable);
            AppSettings settings = AppSettings.Load();
            settings.LaunchAtLogin = enabled;
            if (!settings.Save()) throw new IOException();
        }
        return new { enabled = auto.Enabled, command = auto.Command, legacyRemoved = auto.LegacyRemoved };
    }
}
