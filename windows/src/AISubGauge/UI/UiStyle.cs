using System;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace AISubGauge.UI;

internal static class UiStyle
{
    public static Color Green => ThemeCatalog.Shared.Quota("high");
    public static Color Yellow => ThemeCatalog.Shared.Quota("mid");
    public static Color Red => ThemeCatalog.Shared.Quota("low");
    public static Color Text => AppTheme.Color("textPrimary");
    public static Color Muted => AppTheme.Color("textSecondary");
    public static Color Background => AppTheme.Color("background");
    public static Color Card => AppTheme.Color("surface");

    public static Color QuotaColor(double? value)
    {
        if (value is not double remaining) return Muted;
        if (remaining >= 50) return Green;
        if (remaining <= 15) return Red;
        return remaining < 32.5
            ? Mix(Red, Yellow, (remaining - 15) / 17.5)
            : Mix(Yellow, Green, (remaining - 32.5) / 17.5);
    }

    private static Color Mix(Color from, Color to, double amount) => Color.FromArgb(
        (int)Math.Round(from.R + (to.R - from.R) * amount),
        (int)Math.Round(from.G + (to.G - from.G) * amount),
        (int)Math.Round(from.B + (to.B - from.B) * amount));

    public static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
    {
        float diameter = Math.Max(0.1f, Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height)));
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
