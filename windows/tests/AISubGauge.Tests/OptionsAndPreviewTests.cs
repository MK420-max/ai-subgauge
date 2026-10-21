using System.Linq;
using AISubGauge;
using AISubGauge.UI;
using AISubGauge.Providers;
using Xunit;

namespace AISubGauge.Tests;

public sealed class OptionsAndPreviewTests
{
    [Theory]
    [InlineData("on")]
    [InlineData("off")]
    [InlineData("status")]
    public void AutostartHasAHeadlessCommand(string action)
    {
        Assert.True(AppOptions.TryParse(new[] { "--autostart", action }, out AppOptions options));
        Assert.Equal(action, options.AutoStartAction);
        Assert.False(options.Status);
    }

    [Theory]
    [InlineData("--autostart", "invalid")]
    [InlineData("--autostart", "")]
    [InlineData("--status", "--selftest-grok-refresh")]
    [InlineData("--demo", "--selftest-grok-refresh")]
    [InlineData("--screenshot", "--status")]
    [InlineData("--demo", "--codex-signer")]
    [InlineData("--status", "--codex-signer")]
    public void InvalidOrConflictingModesAreRejected(string first, string second) =>
        Assert.False(AppOptions.TryParse(new[] { first, second }, out _));

    [Fact]
    public void CodexSignerIsAStandaloneHeadlessMode()
    {
        Assert.True(AppOptions.TryParse(new[] { "--codex-signer" }, out AppOptions options));
        Assert.True(options.CodexSigner);
        Assert.False(options.Status);
    }

    [Fact]
    public void OfflinePreviewContainsTheRequestedValuesAndLabelledError()
    {
        var data = ScreenshotCapture.PreviewData(false);
        Assert.Equal(new[] { "codex", "grok", "claude" }, data.Select(item => item.Provider.Id));
        Assert.Equal(new double?[] { 72, 45, 88 }, data.Select(item => item.RemainingPercent));
        Assert.All(data, item => Assert.True(item.IsDemo));
        Assert.All(data, item => Assert.Null(item.Error));
        Assert.Equal(new[] { 12000d, 86400d, 432000d }, data.Select(item =>
            (item.MainWindow!.ResetsAt!.Value - ScreenshotCapture.PreviewNow).TotalSeconds));
        Assert.StartsWith(GrokCliRefresh.FailurePrefix, ScreenshotCapture.PreviewData(true).Single(item => item.Provider.Id == "grok").Error);
    }

    [Fact]
    public void PercentAndResetMatchTheSharedCopy()
    {
        Assert.Equal("72%", QuotaText.Percent(72));
        Assert.Equal("—", QuotaText.Percent(null));
        Assert.Equal(I18n.Get("panel.resetPrefix") + I18n.Get("common.notProvided"), QuotaText.Reset(null));
    }

    [Theory]
    [InlineData("--screenshot", "en")]
    [InlineData("--screenshot", "zh-Hans")]
    [InlineData("--render-preview", "en")]
    [InlineData("--render-preview", "zh-Hans")]
    public void ExportLanguageMayPrecedeOrFollowTheMode(string mode, string language)
    {
        Assert.True(AppOptions.TryParse(new[] { "--lang", language, mode, "output" }, out AppOptions before));
        Assert.True(AppOptions.TryParse(new[] { mode, "output", "--lang", language }, out AppOptions after));
        Assert.Equal(language, before.Language);
        Assert.Equal(before, after);
    }

    [Fact]
    public void RunningStatusIsASeparateModeAndInvalidLanguagesAreRejected()
    {
        Assert.True(AppOptions.TryParse(new[] { "--running-status" }, out AppOptions options));
        Assert.True(options.RunningStatus);
        Assert.False(AppOptions.TryParse(new[] { "--running-status", "--status" }, out _));
        Assert.False(AppOptions.TryParse(new[] { "--running-status", "--demo" }, out _));
        Assert.False(AppOptions.TryParse(new[] { "--lang" }, out _));
        Assert.False(AppOptions.TryParse(new[] { "--render-preview", "out", "--lang", "fr" }, out _));
        Assert.False(AppOptions.TryParse(new[] { "--lang", "en", "--lang", "zh-Hans" }, out _));
    }

    [Theory]
    [InlineData("--screenshot", "en", "light")]
    [InlineData("--screenshot", "zh-Hans", "dark")]
    [InlineData("--render-preview", "en", "dark")]
    [InlineData("--render-preview", "zh-Hans", "light")]
    public void ThemeAndLanguageMayAppearInEitherOrder(string mode, string language, string theme)
    {
        Assert.True(AppOptions.TryParse(new[] { "--theme", theme, "--lang", language, mode, "out" }, out AppOptions before));
        Assert.True(AppOptions.TryParse(new[] { mode, "out", "--lang", language, "--theme", theme }, out AppOptions after));
        Assert.Equal(before, after);
        Assert.Equal(theme, before.Theme);
        Assert.Equal($"win-panel-{theme}-{language}.png", ScreenshotCapture.PanelFileName(theme, language));
    }

    [Fact]
    public void InvalidMissingAndRepeatedThemeFlagsAreRejected()
    {
        Assert.False(AppOptions.TryParse(new[] { "--theme" }, out _));
        Assert.False(AppOptions.TryParse(new[] { "--render-preview", "out", "--theme", "system" }, out _));
        Assert.False(AppOptions.TryParse(new[] { "--theme", "light", "--theme", "dark" }, out _));
    }
}
