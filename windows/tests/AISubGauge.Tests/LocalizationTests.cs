using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using AISubGauge.UI;
using Xunit;

namespace AISubGauge.Tests;

public sealed class LocalizationTests
{
    [Theory]
    [InlineData("invalid JSON")]
    [InlineData("null")]
    [InlineData("{\"app.name\":null}")]
    public void InvalidCatalogFallsBackToBuiltinEnglish(string json)
    {
        using var stream = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(json));
        Assert.Equal("AI SubGauge", I18n.Load(stream)["app.name"]);
    }

    [Theory]
    [InlineData(0, true)]
    [InlineData(1, false)]
    public void CatalogReadLimitIsOneMiBIncludingWhitespace(int extra, bool accepted)
    {
        const string json = "{\"app.name\":\"Fixture\"}";
        byte[] bytes = System.Text.Encoding.UTF8.GetBytes(json + new string(' ', SharedResources.MaxBytes + extra - json.Length));
        using var stream = new MemoryStream(bytes);
        Assert.Equal(accepted ? "Fixture" : "AI SubGauge", I18n.Load(stream)["app.name"]);
    }

    [Fact]
    public void MissingEnglishKeysDisplayTheKeyEvenWithFormatArguments()
    {
        string previous = I18n.Language;
        try
        {
            I18n.Initialize("en");
            Assert.Equal("missing.test.key", I18n.Get("missing.test.key"));
            Assert.Equal("missing.test.key", I18n.Get("missing.test.key", 42));
        }
        finally { I18n.Initialize(previous); }
    }

    [Fact]
    public void BundledLanguagesHaveIdenticalKeysNoEmptyValuesAndEverySourceReferenceExists()
    {
        Dictionary<string, string> en = I18n.Load("en"), zh = I18n.Load("zh-Hans");
        Assert.NotEmpty(en);
        Assert.Equal(en.Keys.OrderBy(key => key), zh.Keys.OrderBy(key => key));
        Assert.All(en.Keys, key =>
        {
            Assert.False(string.IsNullOrWhiteSpace(en[key]), key);
            Assert.False(string.IsNullOrWhiteSpace(zh[key]), key);
            Assert.Equal(Regex.Matches(en[key], @"\{\d+\}").Select(match => match.Value).Distinct().OrderBy(value => value),
                Regex.Matches(zh[key], @"\{\d+\}").Select(match => match.Value).Distinct().OrderBy(value => value));
        });
        DirectoryInfo? root = new(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "AISubGauge.sln"))) root = root.Parent;
        Assert.NotNull(root);
        var references = new HashSet<string>();
        foreach (string file in Directory.EnumerateFiles(Path.Combine(root!.FullName, "src"), "*.cs", SearchOption.AllDirectories))
        foreach (Match match in Regex.Matches(File.ReadAllText(file), "\\bI18n\\.Get\\(\\s*\"([^\"\\n]+)\""))
            references.Add(match.Groups[1].Value);
        Assert.NotEmpty(references);
        Assert.All(references, key => Assert.True(en.ContainsKey(key), key));
    }

    [Theory]
    [InlineData(null, "zh-TW", "zh-Hans")]
    [InlineData("system", "zh-CN", "zh-Hans")]
    [InlineData(null, "en-CA", "en")]
    [InlineData("system", "fr-FR", "en")]
    [InlineData("en", "zh-CN", "en")]
    [InlineData("zh-Hans", "en-US", "zh-Hans")]
    public void LanguageSelectionUsesThePreferenceThenTheSystem(string? preference, string system, string expected) =>
        Assert.Equal(expected, I18n.ResolveLanguage(preference, system));

    [Theory]
    [InlineData("en", "Account quota", "Resets: Not provided")]
    [InlineData("zh-Hans", "账户余量", "重置：未提供")]
    public void PreviewUsesTheRequestedLanguage(string language, string title, string reset)
    {
        string previous = I18n.Language;
        try
        {
            I18n.Initialize(language);
            Assert.Equal(title, I18n.Get("panel.title"));
            Assert.Equal(reset, QuotaText.Reset(null));
            Assert.All(ScreenshotCapture.PreviewData(false), snapshot =>
            {
                Assert.True(snapshot.IsDemo);
                Assert.Equal(I18n.Get("windows.demo.plan"), snapshot.Plan);
                Assert.Contains(I18n.Get("demo.label"), QuotaText.Tooltip(snapshot.Provider.DisplayName, snapshot));
            });
        }
        finally { I18n.Initialize(previous); }
    }

    [Fact]
    public void ExistingSettingsWithoutLanguageFollowSystemAndNewPreferencesRoundTrip()
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        string directory = Path.Combine(root, "AISubGauge");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "settings.json"), "{\"ProviderVisibility\":{\"codex\":true}}");
        AppSettings settings = AppSettings.Load(root);
        Assert.Equal("system", settings.Language);
        Assert.False(settings.AlwaysShowAll);
        settings.Language = "zh-Hans";
        settings.AlwaysShowAll = true;
        Assert.True(settings.Save());
        AppSettings loaded = AppSettings.Load(root);
        Assert.Equal("zh-Hans", loaded.Language);
        Assert.True(loaded.AlwaysShowAll);
        Assert.True(loaded.ProviderVisibility["codex"]);
    }
}
