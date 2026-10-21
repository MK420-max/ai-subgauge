using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using AISubGauge.Providers;
using AISubGauge;
using Microsoft.Win32;
using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace AISubGauge.Tests;

public sealed class SettingsAndAutoStartTests
{
    internal static string NewDirectory()
    {
        string directory = Path.Combine(Path.GetTempPath(), "aisubgauge-tests-" + Guid.NewGuid().ToString("N"));
        CredentialAccess.CreatePrivateDirectory(directory);
        return directory;
    }

    [Fact]
    public void MigrationPreservesVisibilityWithoutGrantingConsent()
    {
        string root = NewDirectory();
        string legacy = Path.Combine(root, "WindowsQuotaTray", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        const string original = "{\"ProviderVisibility\":{\"claude\":false,\"codex\":true,\"grok\":null},\"LegacyStrip\":true}";
        File.WriteAllText(legacy, original);
        AppSettings settings = AppSettings.Load(root);
        Assert.Equal(original, File.ReadAllText(legacy));
        Assert.True(File.Exists(Path.Combine(root, "AISubGauge", "settings.json")));
        Assert.All(ProviderRegistry.CreateEnabled(), provider =>
        {
            Assert.False(settings.HasConsent(provider.Id));
            Assert.True(settings.NeedsConsent(provider.Id));
        });
        Assert.True(settings.ProviderVisibility["codex"]);
        Assert.Null(settings.ProviderVisibility["grok"]);
        Assert.False(settings.IsVisible("claude", true, false));
        settings.ProviderConsent["codex"] = false;
        Assert.True(settings.Save());
        Assert.False(AppSettings.Load(root).HasConsent("codex"));
        Assert.False(AppSettings.Load(root).NeedsConsent("codex"));
        Assert.True(AppSettings.Load(root).NeedsConsent("grok"));
        Assert.Equal(original, File.ReadAllText(legacy));
    }

    [Fact]
    public void FreshSettingsRequireConsentSeparatelyAndDefaultAutostartToNull()
    {
        AppSettings settings = AppSettings.Load(NewDirectory());
        Assert.Null(settings.LaunchAtLogin);
        Assert.All(ProviderRegistry.CreateEnabled(), provider => Assert.False(settings.HasConsent(provider.Id)));
        settings.ProviderConsent["codex"] = true;
        settings.ProviderConsent["claude"] = false;
        Assert.True(settings.Save());
        Assert.True(settings.HasConsent("codex"));
        Assert.False(settings.HasConsent("grok"));
        Assert.True(settings.NeedsConsent("grok"));
        Assert.False(settings.NeedsConsent("claude"));
    }

    [Fact]
    public void ExistingNewSettingsWinOverLegacy()
    {
        string root = NewDirectory();
        AppSettings settings = AppSettings.Load(root);
        settings.LaunchAtLogin = false;
        settings.ProviderConsent["codex"] = true;
        settings.ProviderConsent["claude"] = false;
        Assert.True(settings.Save());
        string legacy = Path.Combine(root, "WindowsQuotaTray");
        Directory.CreateDirectory(legacy);
        File.WriteAllText(Path.Combine(legacy, "settings.json"), "{\"LaunchAtLogin\":true}");
        Assert.Equal(false, AppSettings.Load(root).LaunchAtLogin);
        Assert.True(AppSettings.Load(root).HasConsent("codex"));
        Assert.False(AppSettings.Load(root).HasConsent("claude"));
        Assert.False(AppSettings.Load(root).NeedsConsent("claude"));
        Assert.True(AppSettings.Load(root).NeedsConsent("grok"));
    }

    [Fact]
    public void ReadOnlyLoadDoesNotMigrateLegacySettings()
    {
        string root = NewDirectory();
        string legacy = Path.Combine(root, "WindowsQuotaTray", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        const string original = "{\"ProviderVisibility\":{\"codex\":true}}";
        File.WriteAllText(legacy, original);
        AppSettings settings = AppSettings.Load(root, migrate: false);
        Assert.True(settings.ProviderVisibility["codex"]);
        Assert.False(settings.HasConsent("codex"));
        Assert.True(settings.NeedsConsent("codex"));
        Assert.False(Directory.Exists(Path.Combine(root, "AISubGauge")));
        Assert.Equal(original, File.ReadAllText(legacy));
    }

    [Theory]
    [InlineData("settings")]
    [InlineData(@"C:settings")]
    [InlineData(@"\\server\share\settings")]
    public void SettingsOverrideRequiresAnAbsoluteLocalPath(string value)
    {
        string? previous = Environment.GetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR");
        try
        {
            Environment.SetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR", value);
            Assert.ThrowsAny<Exception>(() => AppSettings.Load());
        }
        finally { Environment.SetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR", previous); }
    }

    [Fact]
    public void SettingsOverrideIsTheWholeRootAndDemoSaveIsInMemoryOnly()
    {
        string root = NewDirectory();
        string? previous = Environment.GetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR");
        try
        {
            Environment.SetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR", root);
            AppSettings settings = AppSettings.Load();
            Assert.Equal(Path.Combine(root, "settings.json"), settings.SettingsPath);
            settings.ProviderConsent["codex"] = true;
            Assert.True(settings.Save());
            string original = File.ReadAllText(settings.SettingsPath);
            Assert.True(AppSettings.Load().HasConsent("codex"));
            AppSettings demo = AppSettings.ForDemo();
            Assert.False(demo.HasConsent("codex"));
            demo.Language = "zh-Hans";
            Assert.True(demo.Save());
            Assert.Equal(original, File.ReadAllText(settings.SettingsPath));
        }
        finally { Environment.SetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR", previous); }
    }

    [Fact]
    public void RegistryCommandsUseQuotedPathAndNeverTouchTheRealRunKey()
    {
        string subkey = @"Software\AISubGauge.Tests\" + Guid.NewGuid().ToString("N");
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(subkey);
            string root = NewDirectory();
            string installation = Path.Combine(root, "Programs", "AISubGauge");
            CredentialAccess.CreatePrivateDirectory(installation);
            var auto = new AutoStart(key, "TestNew", "TestOld", installation, trustedAncestor: root);
            string exe = Path.Combine(installation, "AISubGauge.exe");
            File.WriteAllText(exe, "synthetic executable fixture");
            auto.Apply(true, exe);
            Assert.True(auto.Enabled);
            Assert.Equal("\"" + exe + "\"", auto.Command);
            Assert.Equal(RegistryValueKind.String, key.GetValueKind("TestNew"));
            auto.Apply(false, exe);
            Assert.False(auto.Enabled);
            Assert.Null(auto.Command);
            key.SetValue("TestOld", "\"C:\\Old App\\WindowsQuotaTray.exe\"");
            auto.Migrate(exe);
            Assert.True(auto.LegacyRemoved);
            Assert.Null(key.GetValue("TestOld"));
            Assert.Equal("\"" + exe + "\"", auto.Command);
            key.SetValue("TestOld", "\"C:\\Other\\other.exe\"");
            var unrelated = new AutoStart(key, "OtherNew", "TestOld", installation, trustedAncestor: root);
            unrelated.Migrate(exe);
            Assert.False(unrelated.LegacyRemoved);
            Assert.NotNull(key.GetValue("TestOld"));
            Assert.Null(key.GetValue("AISubGauge"));
        }
        finally { Registry.CurrentUser.DeleteSubKeyTree(subkey, throwOnMissingSubKey: false); }
    }

    [Theory]
    [InlineData("\"C:\\Old App\\WindowsQuotaTray.exe\"", true)]
    [InlineData("\"C:\\Other\\other.exe\"", false)]
    public void DisabledStartupRemovesOnlyRecognizedLegacyRunValue(string command, bool removed)
    {
        string subkey = @"Software\AISubGauge.Tests\" + Guid.NewGuid().ToString("N");
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(subkey);
            key.SetValue("AISubGauge", "\"C:\\Old App\\AISubGauge.exe\"");
            key.SetValue("WindowsQuotaTray", command);
            key.SetValue("UnrelatedValue", "\"C:\\Old App\\WindowsQuotaTray.exe\"");
            var auto = new AutoStart(key);
            AppSettings settings = AppSettings.Load(NewDirectory());
            settings.LaunchAtLogin = false;
            AutoStart.Initialize(settings, auto, @"C:\Unprotected\AISubGauge.exe");
            Assert.Equal(false, settings.LaunchAtLogin);
            Assert.False(auto.Enabled);
            Assert.Null(auto.Command);
            Assert.Equal(removed, auto.LegacyRemoved);
            Assert.Null(key.GetValue("AISubGauge"));
            Assert.Equal(removed ? null : command, key.GetValue("WindowsQuotaTray") as string);
            Assert.Equal("\"C:\\Old App\\WindowsQuotaTray.exe\"", key.GetValue("UnrelatedValue") as string);
        }
        finally { Registry.CurrentUser.DeleteSubKeyTree(subkey, throwOnMissingSubKey: false); }
    }

    [Theory]
    [InlineData("\"C:\\Old App\\WindowsQuotaTray.exe\"", true)]
    [InlineData("\"C:\\Other\\other.exe\"", false)]
    public void AutostartOffRemovesOnlyRecognizedLegacyRunValueAndSavesPreference(string command, bool removed)
    {
        string subkey = @"Software\AISubGauge.Tests\" + Guid.NewGuid().ToString("N");
        string? previous = Environment.GetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR");
        try
        {
            Environment.SetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR", NewDirectory());
            AppSettings settings = AppSettings.Load();
            settings.LaunchAtLogin = true;
            Assert.True(settings.Save());
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(subkey);
            key.SetValue("AISubGauge", "\"C:\\Old App\\AISubGauge.exe\"");
            key.SetValue("WindowsQuotaTray", command);
            key.SetValue("UnrelatedValue", "\"C:\\Old App\\WindowsQuotaTray.exe\"");
            var auto = new AutoStart(key);
            using JsonDocument report = JsonDocument.Parse(JsonSerializer.Serialize(
                AutoStart.RunCommand("off", auto, @"C:\Unprotected\AISubGauge.exe")));
            Assert.Equal(false, AppSettings.Load().LaunchAtLogin);
            Assert.False(report.RootElement.GetProperty("enabled").GetBoolean());
            Assert.Equal(JsonValueKind.Null, report.RootElement.GetProperty("command").ValueKind);
            Assert.Equal(removed, report.RootElement.GetProperty("legacyRemoved").GetBoolean());
            Assert.Null(key.GetValue("AISubGauge"));
            Assert.Equal(removed ? null : command, key.GetValue("WindowsQuotaTray") as string);
            Assert.Equal("\"C:\\Old App\\WindowsQuotaTray.exe\"", key.GetValue("UnrelatedValue") as string);
        }
        finally
        {
            Environment.SetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR", previous);
            Registry.CurrentUser.DeleteSubKeyTree(subkey, throwOnMissingSubKey: false);
        }
    }

    [Theory]
    [InlineData("\"C:\\Old App\\WindowsQuotaTray.exe\"", true)]
    [InlineData("\"C:\\Other\\other.exe\"", false)]
    public void AutostartStatusReportsRecognizedLegacyRunValueWithoutChangingIt(string command, bool enabled)
    {
        string subkey = @"Software\AISubGauge.Tests\" + Guid.NewGuid().ToString("N");
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(subkey);
            key.SetValue("WindowsQuotaTray", command);
            using JsonDocument report = JsonDocument.Parse(JsonSerializer.Serialize(
                AutoStart.RunCommand("status", new AutoStart(key), @"C:\Unprotected\AISubGauge.exe")));
            Assert.Equal(enabled, report.RootElement.GetProperty("enabled").GetBoolean());
            Assert.Equal(enabled ? command : null, report.RootElement.GetProperty("command").GetString());
            Assert.False(report.RootElement.GetProperty("legacyRemoved").GetBoolean());
            Assert.Equal(command, key.GetValue("WindowsQuotaTray") as string);
            Assert.Null(key.GetValue("AISubGauge"));
        }
        finally { Registry.CurrentUser.DeleteSubKeyTree(subkey, throwOnMissingSubKey: false); }
    }

    [Theory]
    [InlineData("WindowsQuotaTray.exe", false)]
    [InlineData("\"C:\\old\\WindowsQuotaTray.exe\" --other", false)]
    [InlineData("C:\\old\\WindowsQuotaTray.exe", true)]
    [InlineData("\"C:\\old app\\WindowsQuotaTray.exe\"", true)]
    public void LegacyMigrationRecognizesOnlyTheOldExecutable(string command, bool expected) =>
        Assert.Equal(expected, AutoStart.IsLegacyCommand(command));

    [Fact]
    public void MacProviderOrderPrecedesWindowsOnlyProviders() =>
        Assert.Equal(new[] { "codex", "claude", "grok", "gemini", "copilot", "kimi", "glm" },
            ProviderRegistry.CreateEnabled().Select(provider => provider.Id));
}
