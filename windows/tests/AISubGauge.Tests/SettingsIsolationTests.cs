using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Xunit;

namespace AISubGauge.Tests;

public sealed class SettingsIsolationTests
{
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task HeadlessStatusDoesNotCreateSettingsOrMigrateLegacySettings(bool demo)
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        string legacy = Path.Combine(root, "WindowsQuotaTray", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        const string original = "{\"ProviderVisibility\":{\"codex\":true},\"Language\":\"zh-Hans\"}";
        File.WriteAllText(legacy, original);
        string output = await RunAsync(root, demo ? new[] { "--demo", "--status" } : new[] { "--status" });
        using JsonDocument json = JsonDocument.Parse(output);
        Assert.Equal(7, json.RootElement.GetArrayLength());
        Assert.All(json.RootElement.EnumerateArray(), entry => Assert.False(entry.GetProperty("consent").GetBoolean()));
        Assert.False(File.Exists(Path.Combine(root, "settings.json")));
        Assert.False(File.Exists(Path.Combine(root, "settings.json.tmp")));
        Assert.False(Directory.Exists(Path.Combine(root, "AISubGauge")));
        Assert.Equal(original, File.ReadAllText(legacy));
    }

    [Fact]
    public async Task DemoStatusIgnoresExistingAuthorizedSettingsAndPreservesTheirBytes()
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        string settings = Path.Combine(root, "settings.json");
        const string original = "{\"ProviderConsent\":{\"codex\":true,\"grok\":true},\"Language\":\"zh-Hans\"}";
        File.WriteAllText(settings, original);
        using JsonDocument json = JsonDocument.Parse(await RunAsync(root, new[] { "--demo", "--status" }));
        Assert.All(json.RootElement.EnumerateArray(), entry =>
        {
            Assert.False(entry.GetProperty("consent").GetBoolean());
            Assert.False(entry.GetProperty("isSignedInLocally").GetBoolean());
            Assert.True(entry.GetProperty("isDemo").GetBoolean());
        });
        Assert.Equal(original, File.ReadAllText(settings));
    }

    [Fact]
    public async Task SignerCommandReportsAnUnsignedFixtureWithoutExecutingItOrLoadingSettings()
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        using JsonDocument json = JsonDocument.Parse(await RunAsync(root, new[] { "--codex-signer" }));
        JsonElement result = Assert.Single(json.RootElement.EnumerateArray());
        Assert.StartsWith("InvalidSignature", result.GetProperty("Status").GetString());
        Assert.Equal(JsonValueKind.Null, result.GetProperty("Subject").ValueKind);
        Assert.Equal(2, System.Linq.Enumerable.Count(result.EnumerateObject()));
        Assert.Empty(Directory.EnumerateFileSystemEntries(root));
    }

    private static async Task<string> RunAsync(string settingsRoot, string[] arguments)
    {
        var info = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "AppHost", "AISubGauge.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.Environment["AISUBGAUGE_SETTINGS_DIR"] = settingsRoot;
        info.Environment["CODEX_EXE"] = Path.Combine(AppContext.BaseDirectory, "FakeGrokCli", "FakeGrokCli.exe");
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info)!;
        try
        {
            Task<string> stdout = process.StandardOutput.ReadToEndAsync();
            Task<string> stderr = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
            Assert.Equal(0, process.ExitCode);
            Assert.Empty(await stderr);
            return await stdout;
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
            }
        }
    }
}
