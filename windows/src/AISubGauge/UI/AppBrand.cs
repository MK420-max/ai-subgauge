using System;
using System.Drawing;
using System.IO;

namespace AISubGauge.UI;

internal static class AppBrand
{
    internal static Bitmap Logo(LogoCatalog logos) => logos.Get("AISubGauge.shared.brand.app-" + AppTheme.Current + "-1024.png");

    internal static Icon WindowIcon()
    {
        using Stream stream = SharedResources.Open("brand.AISubGauge-light.ico");
        using var icon = new Icon(stream);
        return (Icon)icon.Clone();
    }

    internal static string IdleResource(int size, bool taskbarDark)
    {
        int pixels = Array.Find(new[] { 16, 18, 20, 24, 32, 36, 64 }, candidate => candidate >= size);
        if (pixels == 0) pixels = 64;
        return "brand.tray-mono" + (taskbarDark ? "-white" : "") + "-" + pixels + ".png";
    }
}
