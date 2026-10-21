using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using AISubGauge.UI;
using Xunit;

namespace AISubGauge.Tests;

public sealed class RunningVisibilityTests
{
    private static readonly DateTimeOffset Start = DateTimeOffset.UnixEpoch;
    private static Dictionary<string, bool> Running(bool codex, bool claude = false) =>
        new() { ["codex"] = codex, ["claude"] = claude };

    [Fact]
    public void DisappearanceKeeps29SecondsHidesAt31AndReappearanceIsImmediate()
    {
        var state = new RunningVisibility();
        Assert.Contains("codex", state.Update(Start, Running(true)));
        state.Update(Start.AddSeconds(5), Running(false));
        Assert.Contains("codex", state.Update(Start.AddSeconds(5 + 29), Running(false)));
        Assert.DoesNotContain("codex", state.Update(Start.AddSeconds(5 + 31), Running(false)));
        Assert.Contains("codex", state.Update(Start.AddSeconds(5 + 31), Running(true)));
        state.Update(Start.AddSeconds(40), Running(false));
        Assert.Contains("codex", state.Update(Start.AddSeconds(69), Running(false)));
        Assert.DoesNotContain("codex", state.Update(Start.AddSeconds(70), Running(false)));
    }

    [Fact]
    public void ReappearanceDuringGraceRestartsTheNextGraceAndProvidersAreIndependent()
    {
        var state = new RunningVisibility();
        state.Update(Start, Running(true, true));
        state.Update(Start.AddSeconds(5), Running(false, true));
        state.Update(Start.AddSeconds(20), Running(true, false));
        var visible = state.Update(Start.AddSeconds(51), Running(true, false));
        Assert.Contains("codex", visible);
        Assert.DoesNotContain("claude", visible);
        state.Update(Start.AddSeconds(55), Running(false));
        Assert.Contains("codex", state.Update(Start.AddSeconds(84), Running(false)));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SelectionIncludingLocalLoginDefaultsAlwaysApplies(bool alwaysShowAll)
    {
        var settings = new AppSettings { AlwaysShowAll = alwaysShowAll };
        settings.ProviderVisibility["claude"] = false; // Signed in but explicitly hidden.
        settings.ProviderVisibility["grok"] = true; // Selected even without a local login.
        var ids = new[] { "codex", "claude", "grok", "gemini" };
        string[] selected = ids.Where(id => settings.IsVisible(id, id is "codex" or "claude", false)).ToArray();
        var display = RunningVisibility.Select(selected, new HashSet<string> { "codex", "claude", "gemini" }, alwaysShowAll);
        Assert.Contains("codex", display.Providers);
        Assert.DoesNotContain("claude", display.Providers);
        Assert.DoesNotContain("gemini", display.Providers);
        Assert.Equal(alwaysShowAll, display.Providers.Contains("grok"));
        Assert.False(display.ShowIdle);
    }

    [Fact]
    public void IdleAppearsWithNoVisibleProvidersAndDisappearsWhenAnyProviderReturns()
    {
        var state = new RunningVisibility();
        Assert.True(RunningVisibility.Select(new[] { "codex" }, state.Update(Start, Running(false)), false).ShowIdle);
        Assert.False(RunningVisibility.Select(new[] { "codex" }, state.Update(Start, Running(true)), false).ShowIdle);
        state.Update(Start.AddSeconds(5), Running(false));
        Assert.False(RunningVisibility.Select(new[] { "codex" }, state.Update(Start.AddSeconds(34), Running(false)), false).ShowIdle);
        Assert.True(RunningVisibility.Select(new[] { "codex" }, state.Update(Start.AddSeconds(36), Running(false)), false).ShowIdle);
        Assert.False(RunningVisibility.Select(new[] { "codex" }, new HashSet<string>(), true).ShowIdle);
        Assert.True(RunningVisibility.Select(Array.Empty<string>(), new HashSet<string> { "codex" }, true).ShowIdle);
    }

    [Fact]
    public void ProcessNamesUseExactCaseInsensitiveImageNamesWithoutExe()
    {
        using Stream resource = SharedResources.Open("running-processes.json");
        var mapping = JsonSerializer.Deserialize<Dictionary<string, string[]>>(resource)!;
        var matches = RunningProcesses.Match(mapping, new[] { "CHATGPT", "Grok Bot", "CLAUDE", "gemini.exe", "my-copilot", "ZAI" });
        Assert.True(matches["codex"]);
        Assert.True(matches["grok"]);
        Assert.True(matches["claude"]);
        Assert.True(matches["glm"]);
        Assert.False(matches["gemini"]);
        Assert.False(matches["copilot"]);
        Assert.False(matches["kimi"]);
        Assert.Equal(5000, RunningProcesses.PollIntervalMilliseconds);
    }

    [Fact]
    public void IdleArtworkHasVisibleNeutralGrayPixels()
    {
        using var bitmap = TrayIconRenderer.RenderIdle(24);
        bool ink = false;
        for (int y = 0; y < bitmap.Height; y++)
        for (int x = 0; x < bitmap.Width; x++)
        {
            var pixel = bitmap.GetPixel(x, y);
            if (pixel.A == 0) continue;
            ink = true;
            Assert.Equal(pixel.R, pixel.G);
            Assert.Equal(pixel.G, pixel.B);
        }
        Assert.True(ink);
    }

    [Fact]
    public void SettingsDirectoryMappingReplacesDefaultsAndInvalidFilesFallBack()
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        string path = Path.Combine(root, "running-processes.json");
        File.WriteAllText(path, "{\"codex\":[\"Custom AI\"]}");
        var matches = new RunningProcesses(root).Match(new[] { "custom ai", "claude" });
        Assert.True(matches["codex"]);
        Assert.False(matches["claude"]);
        File.WriteAllText(path, "{\"codex\":null}");
        Assert.True(new RunningProcesses(root).Match(new[] { "ChatGPT" })["codex"]);
        File.WriteAllText(path, "invalid JSON");
        Assert.True(new RunningProcesses(root).Match(new[] { "ChatGPT" })["codex"]);
    }

    [Fact]
    public async Task RunningStatusIsHeadlessAndContainsOnlyProviderBooleans()
    {
        var info = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "AppHost", "AISubGauge.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.Environment["AISUBGAUGE_SETTINGS_DIR"] = SettingsAndAutoStartTests.NewDirectory();
        info.ArgumentList.Add("--running-status");
        using var process = Process.Start(info)!;
        try
        {
            Task<string> stdout = process.StandardOutput.ReadToEndAsync();
            Task<string> stderr = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(0, process.ExitCode);
            Assert.Empty(await stderr);
            using JsonDocument json = JsonDocument.Parse(await stdout);
            Assert.Equal(ProviderRegistry.CreateEnabled().Select(provider => provider.Id).OrderBy(id => id),
                json.RootElement.EnumerateObject().Select(entry => entry.Name).OrderBy(id => id));
            Assert.All(json.RootElement.EnumerateObject(), entry => Assert.True(entry.Value.ValueKind is JsonValueKind.True or JsonValueKind.False));
        }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } }
    }
}
