using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using AISubGauge;
using AISubGauge.Providers;
using AISubGauge.UI;
using Xunit;

namespace AISubGauge.Tests;

public sealed class SecurityTests
{
    [Theory]
    [InlineData(WellKnownSidType.WorldSid)]
    [InlineData(WellKnownSidType.BuiltinUsersSid)]
    [InlineData(WellKnownSidType.AuthenticatedUserSid)]
    public async Task ReadableCredentialIsRejectedBeforeJsonParsing(WellKnownSidType kind)
    {
        string directory = Path.Combine(SettingsAndAutoStartTests.NewDirectory(), "private");
        CredentialAccess.CreatePrivateDirectory(directory);
        string path = Path.Combine(directory, "credential.json");
        File.WriteAllText(path, "deliberately invalid JSON");
        FileSecurity security = new FileInfo(path).GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(kind, null), FileSystemRights.Read, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
        QuotaReadException error = await Assert.ThrowsAsync<QuotaReadException>(async () =>
        { using var json = await CredentialFiles.ReadAsync(path, CancellationToken.None); });
        Assert.Equal(CredentialAccess.UnsafeMessage, error.Message);
    }

    [Fact]
    public async Task PrivateCredentialIsReadableWithoutModification()
    {
        string directory = Path.Combine(SettingsAndAutoStartTests.NewDirectory(), "private");
        CredentialAccess.CreatePrivateDirectory(directory);
        string path = Path.Combine(directory, "credential.json");
        File.WriteAllText(path, "{\"ok\":true}");
        using var json = await CredentialFiles.ReadAsync(path, CancellationToken.None);
        Assert.True(json.RootElement.GetProperty("ok").GetBoolean());
        Assert.Equal("{\"ok\":true}", File.ReadAllText(path));
    }

    [Fact]
    public async Task UnconsentedProviderNeverFetches()
    {
        var provider = new CountingProvider();
        var settings = new AppSettings();
        QuotaSnapshot result = await QuotaService.ReadProviderAsync(provider, false, CancellationToken.None, settings.HasConsent(provider.Id));
        Assert.Equal(0, provider.FetchCount);
        Assert.Equal(I18n.Get("windows.reading.local.login.information.has.not.been.allowed"), result.Error);
        settings.ProviderConsent[provider.Id] = true;
        await QuotaService.ReadProviderAsync(provider, false, CancellationToken.None, settings.HasConsent(provider.Id));
        Assert.Equal(1, provider.FetchCount);
        settings.ProviderConsent[provider.Id] = false;
        await QuotaService.ReadProviderAsync(provider, false, CancellationToken.None, settings.HasConsent(provider.Id));
        Assert.Equal(1, provider.FetchCount);
    }

    [Fact]
    public async Task RefreshFailureFallsBackToClearlyLabelledDemoInPanelAndTooltip()
    {
        var provider = new CountingProvider();
        var settings = new AppSettings();
        settings.ProviderConsent[provider.Id] = true;
        QuotaSnapshot result = await QuotaService.ReadProviderAsync(provider, false, CancellationToken.None, settings.HasConsent(provider.Id));
        Assert.True(result.IsDemo);
        Assert.Equal(CountingProvider.Error, QuotaText.Error(result.Error!));
        Assert.Contains(CountingProvider.Error, QuotaText.Tooltip(provider.DisplayName, result));
        Assert.Contains(I18n.Get("demo.label"), QuotaText.Tooltip(provider.DisplayName, result));
        Assert.Contains(CountingProvider.Error, Diagnostics.Create(new[] { result }));
    }

    [Theory]
    [InlineData("email user@example.org", "user@example.org")]
    [InlineData(@"C:\Users\example\file.json", "example")]
    [InlineData(@"C:\Users\example user\file.json", "example user")]
    [InlineData("SSID=\"Private Network\"", "Private Network")]
    [InlineData("{\"latitude\":49.2827,\"longitude\":-123.1207}", "49.2827")]
    [InlineData("coordinates=[49.2827, -123.1207]", "-123.1207")]
    [InlineData("Bearer sk-test-private123456789", "sk-test-private123456789")]
    [InlineData("{\"access_token\":\"secret-value\"}", "secret-value")]
    [InlineData("token=short-secret", "short-secret")]
    [InlineData("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc12345", "eyJhbGci")]
    [InlineData("host=WORKSTATION-42", "WORKSTATION-42")]
    [InlineData("ghp_abcdefghijklmnopqrstuvwxyz123456", "abcdefghijklmnopqrstuvwxyz")]
    public void DiagnosticsRemoveSensitiveText(string source, string secret)
    {
        string result = Diagnostics.Redact(source, "WORKSTATION-42");
        Assert.DoesNotContain(secret, result);
        Assert.Contains("<", result);
    }

    [Fact]
    public void DiagnosticsIncludeProvidersWithoutASnapshot()
    {
        string text = Diagnostics.Create(Array.Empty<QuotaSnapshot>());
        Assert.All(ProviderRegistry.CreateEnabled(), provider => Assert.Contains(provider.DisplayName, text));
        Assert.Contains(I18n.Get("windows.hidden.or.not.refreshed.yet"), text);
    }

    [Fact]
    public void DiagnosticsPreserveUsefulFacts() =>
        Assert.Equal("AI SubGauge 1.2.0 · 72% · 刷新失败", Diagnostics.Redact("AI SubGauge 1.2.0 · 72% · 刷新失败", "TESTHOST"));

    [Theory]
    [InlineData(@".\grok.exe")]
    [InlineData(@"\\server\share\grok.exe")]
    [InlineData(@"C:\grok.cmd")]
    public void GrokRejectsUntrustedExecutablePaths(string path) => Assert.ThrowsAny<Exception>(() =>
    { using FileStream file = GrokCliRefresh.OpenExecutable(path); });

    [Fact]
    public void GrokEnvironmentDoesNotForwardProviderTokens()
    {
        const string variable = "CLAUDE_CODE_OAUTH_TOKEN";
        string? saved = Environment.GetEnvironmentVariable(variable);
        string? telemetry = Environment.GetEnvironmentVariable("GROK_TELEMETRY_ENABLED");
        string? otel = Environment.GetEnvironmentVariable("GROK_EXTERNAL_OTEL");
        try
        {
            Environment.SetEnvironmentVariable(variable, "sentinel-secret");
            Environment.SetEnvironmentVariable("GROK_TELEMETRY_ENABLED", "1");
            Environment.SetEnvironmentVariable("GROK_EXTERNAL_OTEL", "1");
            var info = GrokCliRefresh.CreateStartInfo(@"C:\grok.exe", @"C:\test", @"C:\auth.json");
            Assert.False(info.UseShellExecute);
            Assert.False(info.Environment.ContainsKey(variable));
            Assert.False(info.Environment.ContainsKey("AISUBGAUGE_TEST_GROK_CLI"));
            Assert.Equal("NUL", info.Environment["GROK_LOG_FILE"]);
            Assert.Equal("off", info.Environment["RUST_LOG"]);
            Assert.Equal("0", info.Environment["GROK_TELEMETRY_ENABLED"]);
            Assert.Equal("0", info.Environment["GROK_EXTERNAL_OTEL"]);
            Assert.All(info.Environment.Keys, key => Assert.True(key is "GROK_LOG_FILE" or "RUST_LOG" or "GROK_TELEMETRY_ENABLED" or "GROK_EXTERNAL_OTEL" ||
                Array.Exists(GrokCliRefresh.EnvironmentAllowlist, name => name.Equals(key, StringComparison.OrdinalIgnoreCase))));
        }
        finally
        {
            Environment.SetEnvironmentVariable(variable, saved);
            Environment.SetEnvironmentVariable("GROK_TELEMETRY_ENABLED", telemetry);
            Environment.SetEnvironmentVariable("GROK_EXTERNAL_OTEL", otel);
        }
    }

    [Fact]
    public void StatusSerializesOnlySafeFieldsAndRedactsErrors()
    {
        const string secret = "sk-test-SENTINEL-DO-NOT-EXPOSE-1234567890";
        var provider = new CountingProvider();
        var snapshot = new QuotaSnapshot
        {
            Provider = provider, Plan = secret, Info = secret, Error = "Bearer " + secret,
            IsDemo = true, Windows = new List<QuotaWindow>
            { new() { Id = "test", Title = secret, RemainingPercent = 55 } }
        };
        string json = JsonSerializer.Serialize(StatusReport.CreateEntry("grok", true, false, snapshot));
        Assert.DoesNotContain(secret, json);
        using JsonDocument document = JsonDocument.Parse(json);
        Assert.False(document.RootElement.GetProperty("consent").GetBoolean());
        Assert.False(document.RootElement.GetProperty("isRealData").GetBoolean());
        Assert.Equal(JsonValueKind.Null, document.RootElement.GetProperty("remainingPercent").ValueKind);
        Assert.Equal(JsonValueKind.Null, document.RootElement.GetProperty("updatedAt").ValueKind);
        Assert.False(document.RootElement.TryGetProperty("Plan", out _));
        Assert.DoesNotContain(secret, Diagnostics.Create(new[] { snapshot }));
    }

    private sealed class CountingProvider : IQuotaProvider
    {
        public static string Error => GrokCliRefresh.FailurePrefix + I18n.Get("windows.the.official.cli.signature.is.invalid.execution.refused");
        public int FetchCount { get; private set; }
        public string Id => "grok";
        public string DisplayName => "Grok Bot";
        public string LogoResource => "";
        public bool IsSignedInLocally() => true;
        public Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
        { FetchCount++; return Task.FromResult(QuotaSnapshot.Failure(this, Error)); }
    }
}
