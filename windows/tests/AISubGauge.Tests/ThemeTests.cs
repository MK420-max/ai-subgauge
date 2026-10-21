using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text.Json;
using AISubGauge;
using AISubGauge.UI;
using AISubGauge.Providers;
using Xunit;

namespace AISubGauge.Tests;

public sealed class ThemeTests
{
    [Theory]
    [InlineData("invalid JSON")]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("{\"themes\":{\"light\":null},\"quota\":null}")]
    public void InvalidThemeFallsBackToHardcodedColors(string json)
    {
        using var stream = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(json));
        ThemeCatalog catalog = ThemeCatalog.Load(stream);
        Assert.Equal(Color.FromArgb(44, 172, 109), catalog.Quota("high"));
        Assert.Equal(Color.FromArgb(42, 33, 64), catalog.Color("light", "textPrimary"));
        Assert.Equal(Color.FromArgb(238, 240, 255), catalog.Color("dark", "textPrimary"));
        Assert.True(catalog.Gradient("light").Length >= 2);
    }

    [Theory]
    [InlineData(0, true)]
    [InlineData(1, false)]
    public void ThemeLimitCountsActualBytesAndRejectsOversizedValidJson(int extra, bool accepted)
    {
        using Stream bundled = SharedResources.Open("theme.json");
        using var reader = new StreamReader(bundled);
        string json = reader.ReadToEnd().Replace("#2CAC6D", "#010203", StringComparison.Ordinal);
        byte[] bytes = System.Text.Encoding.UTF8.GetBytes(json);
        using var padded = new MemoryStream();
        padded.Write(bytes);
        padded.Write(System.Text.Encoding.ASCII.GetBytes(new string(' ', SharedResources.MaxBytes + extra - bytes.Length)));
        padded.Position = 0;
        Assert.Equal(accepted ? Color.FromArgb(1, 2, 3) : Color.FromArgb(44, 172, 109), ThemeCatalog.Load(padded).Quota("high"));
    }

    [Fact]
    public void GrokLogoMatchesTheBuildAndPublicLiquidRenderingAlwaysWorks()
    {
        var provider = new GrokProvider();
        string[] resources = typeof(GrokProvider).Assembly.GetManifestResourceNames();
        Assert.Equal(GrokProvider.HasPrivateLogo, resources.Contains("WindowsQuotaTray.assets.logos.grokbot-head.png"));
        Assert.Equal(GrokProvider.HasPrivateLogo ? "WindowsQuotaTray.assets.logos.grokbot-head.png"
            : "WindowsQuotaTray.assets.logos.grok.png", provider.LogoResource);
        using var logos = new LogoCatalog();
        foreach (string resource in new[] { "WindowsQuotaTray.assets.logos.grok.png", provider.LogoResource }.Distinct())
        foreach (int size in new[] { 16, 24, 32 })
        {
            using Bitmap bitmap = TrayIconRenderer.Render(logos, resource, ScreenshotCapture.PreviewData(false)
                .Single(item => item.Provider.Id == "grok"), size);
            Assert.Equal(new Size(size, size), bitmap.Size);
            Assert.True(Enumerable.Range(0, size).Any(y => Enumerable.Range(0, size).Any(x => bitmap.GetPixel(x, y).A > 0)));
        }
    }

    [Fact]
    public void SharedThemesParseHaveIdenticalKeysAndContainValidColors()
    {
        ThemeCatalog catalog = ThemeCatalog.Load();
        Assert.Equal(new[] { "dark", "light" }, catalog.Themes.Keys.OrderBy(key => key));
        Assert.Equal(catalog.Themes["light"].Keys.OrderBy(key => key), catalog.Themes["dark"].Keys.OrderBy(key => key));
        foreach (var theme in catalog.Themes)
        foreach (var entry in theme.Value)
        {
            if (entry.Value.ValueKind == JsonValueKind.Array) Assert.True(catalog.Gradient(theme.Key).Length >= 2);
            else Assert.InRange(catalog.Color(theme.Key, entry.Key).A, 1, 255);
        }
        Assert.Equal(Color.FromArgb(44, 172, 109), catalog.Quota("high"));
        Assert.Equal(Color.FromArgb(231, 178, 40), catalog.Quota("mid"));
        Assert.Equal(Color.FromArgb(224, 75, 82), catalog.Quota("low"));
        Assert.Equal(Color.FromArgb(102, 255, 255, 255), catalog.Color("light", "buttonFill"));
    }

    [Theory]
    [InlineData(null, false, "light")]
    [InlineData(null, true, "dark")]
    [InlineData("system", false, "light")]
    [InlineData("system", true, "dark")]
    [InlineData("light", true, "light")]
    [InlineData("dark", false, "dark")]
    [InlineData("invalid", true, "dark")]
    public void ManualPreferenceOverridesSystemAndOldSettingsFollowIt(string? preference, bool systemDark, string expected) =>
        Assert.Equal(expected, AppTheme.Resolve(preference, systemDark));

    [Theory]
    [InlineData("light")]
    [InlineData("dark")]
    [InlineData("system")]
    public void ThemeSettingsRoundTripAndMissingOrInvalidValuesFollowSystem(string preference)
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        AppSettings settings = AppSettings.Load(root);
        Assert.Equal("system", settings.Theme);
        settings.Theme = preference;
        Assert.True(settings.Save());
        Assert.Equal(preference, AppSettings.Load(root).Theme);
        File.WriteAllText(settings.SettingsPath, "{\"Theme\":\"invalid\"}");
        Assert.Equal("system", AppSettings.Load(root).Theme);
        File.WriteAllText(settings.SettingsPath, "{}");
        Assert.Equal("system", AppSettings.Load(root).Theme);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void IdleIconsUseTheExactBlackOrWhiteSharedRasterForEveryTaskbarDpi(bool taskbarDark)
    {
        foreach (int size in new[] { 16, 18, 20, 24, 32, 36, 64 })
        {
            string resource = AppBrand.IdleResource(size, taskbarDark);
            Assert.Equal($"brand.tray-mono{(taskbarDark ? "-white" : "")}-{size}.png", resource);
            using Stream stream = SharedResources.Open(resource);
            using var source = new Bitmap(stream);
            using Bitmap actual = TrayIconRenderer.RenderIdle(size, taskbarDark);
            Assert.Equal(source.Size, actual.Size);
            bool ink = false, transparent = false;
            for (int y = 0; y < size; y++)
            for (int x = 0; x < size; x++)
            {
                Color pixel = actual.GetPixel(x, y);
                Color expected = source.GetPixel(x, y);
                Assert.Equal(expected.A, pixel.A);
                if (pixel.A == 0) { transparent = true; continue; }
                ink = true;
                Assert.InRange(pixel.R, expected.R - 2, expected.R + 2); // premultiplied-alpha rounding
                Assert.InRange(pixel.G, expected.G - 2, expected.G + 2); // premultiplied-alpha rounding
                Assert.InRange(pixel.B, expected.B - 2, expected.B + 2); // premultiplied-alpha rounding
            }
            Assert.True(ink && transparent);
        }
    }

    [Fact]
    public void WindowIconAndBothPanelLogosAreEmbedded()
    {
        using Icon icon = AppBrand.WindowIcon();
        Assert.True(icon.Width >= 16);
        foreach (string mode in new[] { "light", "dark" })
        {
            using Stream stream = SharedResources.Open($"brand.app-{mode}-1024.png");
            using var image = new Bitmap(stream);
            Assert.Equal(new Size(1024, 1024), image.Size);
        }
    }

    [Theory]
    [InlineData(0, "low")]
    [InlineData(15, "low")]
    [InlineData(32.5, "mid")]
    [InlineData(50, "high")]
    [InlineData(100, "high")]
    public void QuotaColorThresholdsRetainTheExistingLiquidPalette(double remaining, string key) =>
        Assert.Equal(ThemeCatalog.Shared.Quota(key), UiStyle.QuotaColor(remaining));

    [Theory]
    [InlineData("en", 12000, "resets in 3h 20m")]
    [InlineData("zh-Hans", 12000, "3小时20分后重置")]
    [InlineData("en", 86400, "resets in 1d 0h")]
    [InlineData("zh-Hans", 432000, "5天0小时后重置")]
    [InlineData("en", 1, "resets in 1m")]
    [InlineData("zh-Hans", 0, "已到重置时间")]
    public void RelativeResetTimesMatchMac(string language, int seconds, string expected)
    {
        string previous = I18n.Language;
        try
        {
            I18n.Initialize(language);
            Assert.Equal(expected, QuotaText.PanelReset(ScreenshotCapture.PreviewNow.AddSeconds(seconds), ScreenshotCapture.PreviewNow));
            Assert.Equal(I18n.Get("panel.resetUnknown"), QuotaText.PanelReset(null, ScreenshotCapture.PreviewNow));
        }
        finally { I18n.Initialize(previous); }
    }
}
