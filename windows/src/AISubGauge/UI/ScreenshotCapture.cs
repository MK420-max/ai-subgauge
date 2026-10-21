using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using AISubGauge.Providers;

namespace AISubGauge.UI;

internal static class ScreenshotCapture
{
    internal static readonly DateTimeOffset PreviewNow = DateTimeOffset.FromUnixTimeSeconds(1_792_512_000);
    internal static string PanelFileName(string theme, string language) => $"win-panel-{theme}-{language}.png";
    private static string Suffix => AppTheme.Current + "-" + I18n.Language;

    public static void RenderPreview(string directory, bool includeIconSizes = false)
    {
        Directory.CreateDirectory(directory);
        using var logos = new LogoCatalog();
        using var panel = new DetailsPanel(logos);
        IReadOnlyList<QuotaSnapshot> snapshots = PreviewData(errorExample: false);
        panel.SetData(snapshots, PreviewNow);
        using (Bitmap image = panel.RenderFullContent())
            image.Save(Path.Combine(directory, PanelFileName(AppTheme.Current, I18n.Language)), ImageFormat.Png);
        panel.SetData(PreviewData(errorExample: true), PreviewNow);
        using (Bitmap image = panel.RenderFullContent())
            image.Save(Path.Combine(directory, $"win-error-{Suffix}.png"), ImageFormat.Png);
        const int pixels = 24, zoom = 4;
        using var tray = new Bitmap(pixels * zoom * snapshots.Count, pixels * zoom, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(tray))
        {
            graphics.Clear(UiStyle.Background);
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            for (int index = 0; index < snapshots.Count; index++)
            {
                QuotaSnapshot snapshot = snapshots[index];
                using Bitmap icon = TrayIconRenderer.Render(logos, snapshot.Provider.LogoResource, snapshot, pixels);
                graphics.DrawImage(icon, new Rectangle(index * pixels * zoom, 0, pixels * zoom, pixels * zoom),
                    0, 0, pixels, pixels, GraphicsUnit.Pixel);
                if (includeIconSizes)
                {
                    foreach (int size in new[] { 16, 20, 24, 32 })
                    {
                        using Bitmap sized = TrayIconRenderer.Render(logos, snapshot.Provider.LogoResource, snapshot, size);
                        sized.Save(Path.Combine(directory, $"tray-{snapshot.Provider.Id}-{size}-{Suffix}.png"), ImageFormat.Png);
                    }
                }
            }
        }
        tray.Save(Path.Combine(directory, $"win-tray-{Suffix}.png"), ImageFormat.Png);
        SaveIdle(directory);
    }

    private static void SaveIdle(string directory)
    {
        const int pixels = 24, zoom = 8;
        // Offline examples pair the taskbar and panel themes; live selection uses SystemUsesLightTheme.
        using Bitmap icon = TrayIconRenderer.RenderIdle(pixels, AppTheme.Current == "dark");
        using var enlarged = new Bitmap(pixels * zoom, pixels * zoom, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(enlarged))
        {
            graphics.Clear(UiStyle.Background);
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            graphics.DrawImage(icon, new Rectangle(0, 0, enlarged.Width, enlarged.Height), 0, 0, pixels, pixels, GraphicsUnit.Pixel);
        }
        enlarged.Save(Path.Combine(directory, $"win-idle-{Suffix}.png"), ImageFormat.Png);
    }

    internal static IReadOnlyList<QuotaSnapshot> PreviewData(bool errorExample)
    {
        // Match the Mac fixture exactly. Never detect logins, read credentials or start the service.
        var values = new[] { (Id: "codex", Remaining: 72d, Seconds: 12000),
            (Id: "grok", Remaining: 45d, Seconds: 86400), (Id: "claude", Remaining: 88d, Seconds: 432000) };
        IReadOnlyList<IQuotaProvider> providers = ProviderRegistry.CreateEnabled();
        return values.Select(value => new QuotaSnapshot
        {
            Provider = providers.Single(provider => provider.Id == value.Id),
            Plan = I18n.Get("windows.demo.plan"),
            IsDemo = true,
            Windows = new List<QuotaWindow> { new() { Id = "preview", Title = I18n.Get("windows.preview"),
                RemainingPercent = value.Remaining, ResetsAt = PreviewNow.AddSeconds(value.Seconds) } },
            Error = errorExample && value.Id == "grok"
                ? GrokCliRefresh.FailurePrefix + I18n.Get("windows.the.official.cli.signature.is.invalid.execution.refused") : null,
            UpdatedAt = PreviewNow.UtcDateTime
        }).ToArray();
    }
}
