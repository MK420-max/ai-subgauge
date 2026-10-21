using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AISubGauge;
using AISubGauge.Providers;
using Xunit;

namespace AISubGauge.Tests;

public sealed class GrokRefreshTests
{
    private static string FakeCli => Path.Combine(AppContext.BaseDirectory, "FakeGrokCli", "FakeGrokCli.exe");
    private const string Secret = "sk-test-SENTINEL-DO-NOT-EXPOSE-1234567890";

    [Theory]
    [InlineData("FakeGrokCli", "FakeGrokCli")]
    [InlineData("AppHost", "AISubGauge")]
    public void SubprocessFixturesIncludeTheirOwnRuntime(string directory, string name)
    {
        string root = Path.Combine(AppContext.BaseDirectory, directory);
        Assert.True(File.Exists(Path.Combine(root, "coreclr.dll")));
        Assert.True(File.Exists(Path.Combine(root, "hostpolicy.dll")));
        using JsonDocument config = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, name + ".runtimeconfig.json")));
        JsonElement runtime = config.RootElement.GetProperty("runtimeOptions");
        Assert.False(runtime.TryGetProperty("framework", out _));
        Assert.False(runtime.TryGetProperty("frameworks", out _));
        Assert.True(runtime.GetProperty("includedFrameworks").GetArrayLength() > 0);
    }

    [Theory]
    [InlineData("success")]
    [InlineData("wide-acl")]
    public async Task CliRenewsOnlySyntheticCredentialsAndAclIsChecked(string mode)
    {
        Assert.True(File.Exists(FakeCli));
        var result = await GrokCliRefresh.SelfTestAsync(FakeCli, mode);
        Assert.True(result.success, result.error);
        Assert.Null(result.error);
        Assert.DoesNotContain(Secret, JsonSerializer.Serialize(result));
    }

    [Theory]
    [InlineData("failure")]
    [InlineData("wrong-user")]
    [InlineData("wrong-client")]
    [InlineData("still-expired")]
    [InlineData("oversize")]
    [InlineData("early-exit")]
    public async Task CliFailuresAreSafeAndBounded(string mode)
    {
        var timer = Stopwatch.StartNew();
        var result = await GrokCliRefresh.SelfTestAsync(FakeCli, mode);
        Assert.False(result.success);
        Assert.StartsWith(GrokCliRefresh.FailurePrefix, result.error);
        Assert.DoesNotContain(Secret, JsonSerializer.Serialize(result));
        Assert.True(timer.Elapsed < TimeSpan.FromSeconds(30));
    }

    [Fact]
    public async Task TimeoutKillsTheCliAndDoesNotExposeItsStderr()
    {
        var timer = Stopwatch.StartNew();
        var result = await GrokCliRefresh.SelfTestAsync(FakeCli, "timeout");
        Assert.False(result.success);
        Assert.Contains(I18n.Get("windows.the.official.cli.timed.out.20.seconds"), result.error);
        Assert.DoesNotContain(Secret, JsonSerializer.Serialize(result));
        Assert.InRange(timer.Elapsed.TotalSeconds, 18, 30);
    }

    [Fact]
    public async Task CancellationIsBounded()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        var result = await GrokCliRefresh.SelfTestAsync(FakeCli, "timeout", cancellation.Token);
        Assert.False(result.success);
        Assert.Contains(I18n.Get("windows.test.cancelled"), result.error);
    }

    [Fact]
    public void ProductionSignatureGateRejectsTheUnsignedFixture()
    {
        using FileStream file = GrokCliRefresh.OpenExecutable(FakeCli);
        QuotaReadException error = Assert.Throws<QuotaReadException>(() => Authenticode.Validate(FakeCli, file));
        Assert.Equal(I18n.Get("windows.the.grok.cli.authenticode.signature.is.invalid.or.could.not"), error.Message);
    }

    [Fact]
    public async Task SelfTestCommandOutputsOnlySafeJsonAndNeverForwardsSecrets()
    {
        string app = Path.Combine(AppContext.BaseDirectory, "AppHost", "AISubGauge.exe");
        var info = new ProcessStartInfo(app) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true };
        info.Environment["AISUBGAUGE_SETTINGS_DIR"] = SettingsAndAutoStartTests.NewDirectory();
        foreach (string name in new[] { "DOTNET_ROOT", "DOTNET_ROOT_X64", "DOTNET_ROOT(x86)", "DOTNET_ROOT_X86" })
            info.Environment.Remove(name);
        info.ArgumentList.Add("--selftest-grok-refresh");
        info.ArgumentList.Add("--lang");
        info.ArgumentList.Add(I18n.Language);
        info.Environment["AISUBGAUGE_TEST_GROK_CLI"] = FakeCli;
        info.Environment["AISUBGAUGE_TEST_GROK_MODE"] = "failure";
        info.Environment["CLAUDE_CODE_OAUTH_TOKEN"] = Secret;
        using var process = new Process { StartInfo = info };
        Assert.True(process.Start());
        try
        {
            Task<string> stdout = process.StandardOutput.ReadToEndAsync();
            Task<string> stderr = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            string output = await stdout;
            string errors = await stderr;
            Assert.Equal(0, process.ExitCode);
            Assert.DoesNotContain(Secret, output + errors);
            using JsonDocument json = JsonDocument.Parse(output);
            Assert.False(json.RootElement.GetProperty("success").GetBoolean());
            Assert.StartsWith(GrokCliRefresh.FailurePrefix, json.RootElement.GetProperty("error").GetString());
        }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } }
    }
}
