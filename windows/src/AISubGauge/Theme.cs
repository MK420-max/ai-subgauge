using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using Microsoft.Win32;

namespace AISubGauge;

internal sealed class ThemeCatalog
{
    private const string DefaultJson = """
        {"themes":{
          "light":{"backgroundGradient":["#FCD789","#E9B48A","#C99AA6","#8A6CC0"],
            "background":"#FBF3E8","surface":"#FFFFFF","surfaceAlt":"#F6E9DA","border":"#E4D2C4",
            "textPrimary":"#2A2140","textSecondary":"#6B5F7A","accent":"#8A6CC0","accentAlt":"#E9A65A",
            "barTrack":"#EADFD3","demo":"#C7832E","error":"#C2413A","panelBorder":"#FFFFFF66",
            "glassOverlay":"#FFFFFF70","buttonFill":"#FFFFFF66","buttonBorder":"#FFFFFF99","divider":"#6B5F7A26","wave":"#FFFFFF40"},
          "dark":{"backgroundGradient":["#2B3160","#1A1B42","#130F2E"],
            "background":"#16173A","surface":"#1F2150","surfaceAlt":"#262A5E","border":"#34386E",
            "textPrimary":"#EEF0FF","textSecondary":"#A8B0D8","accent":"#9FB4FF","accentAlt":"#C8D4F2",
            "barTrack":"#2C3068","demo":"#F0B45A","error":"#FF7A70","panelBorder":"#C8D4F233",
            "glassOverlay":"#C8D4F205","buttonFill":"#C8D4F214","buttonBorder":"#C8D4F240","divider":"#C8D4F226","wave":"#C8D4F208"}},
         "quota":{"high":"#2CAC6D","mid":"#E7B228","low":"#E04B52"}}
        """;
    internal static readonly ThemeCatalog Shared = Load();
    internal Dictionary<string, Dictionary<string, JsonElement>> Themes { get; }
    private readonly Dictionary<string, string> _quota;

    private ThemeCatalog(JsonElement root)
    {
        Themes = root.GetProperty("themes").Deserialize<Dictionary<string, Dictionary<string, JsonElement>>>()!;
        _quota = root.GetProperty("quota").Deserialize<Dictionary<string, string>>()!;
    }

    internal static ThemeCatalog Load()
    {
        try
        {
            using Stream stream = SharedResources.Open("theme.json");
            return Load(stream);
        }
        catch (Exception) { return Defaults(); }
    }

    internal static ThemeCatalog Load(Stream stream)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(SharedResources.ReadBounded(stream));
            var catalog = new ThemeCatalog(document.RootElement);
            ThemeCatalog defaults = Defaults();
            foreach (string mode in defaults.Themes.Keys)
            foreach (string key in defaults.Themes[mode].Keys)
            {
                if (key == "backgroundGradient")
                {
                    if (catalog.Gradient(mode).Length < 2) throw new JsonException();
                }
                else _ = catalog.Color(mode, key);
            }
            foreach (string key in defaults._quota.Keys) _ = catalog.Quota(key);
            return catalog;
        }
        catch (Exception) { return Defaults(); }
    }

    private static ThemeCatalog Defaults()
    {
        using JsonDocument document = JsonDocument.Parse(DefaultJson);
        return new ThemeCatalog(document.RootElement);
    }

    internal Color Color(string mode, string key) => ParseColor(Themes[mode][key].GetString()!);
    internal Color[] Gradient(string mode) => Themes[mode]["backgroundGradient"].EnumerateArray()
        .Select(value => ParseColor(value.GetString()!)).ToArray();
    internal Color Quota(string key) => ParseColor(_quota[key]);

    // The shared format is #RRGGBB or #RRGGBBAA (not System.Drawing's ARGB order).
    internal static Color ParseColor(string hex)
    {
        if (hex.Length is not (7 or 9) || hex[0] != '#') throw new FormatException();
        uint value = uint.Parse(hex.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        uint rgb = hex.Length == 9 ? value >> 8 : value;
        return System.Drawing.Color.FromArgb(hex.Length == 9 ? (int)(value & 255) : 255,
            (int)((rgb >> 16) & 255), (int)((rgb >> 8) & 255), (int)(rgb & 255));
    }
}

internal static class AppTheme
{
    private const string Personalize = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private static string _preference = "system";
    internal static string Current { get; private set; } = "light";
    internal static bool TaskbarDark { get; private set; }
    internal static Color Color(string key) => ThemeCatalog.Shared.Color(Current, key);
    internal static event Action? Changed;

    internal static string Resolve(string? preference, bool systemDark) =>
        preference is "light" or "dark" ? preference : systemDark ? "dark" : "light";

    internal static void Initialize(string? preference)
    {
        _preference = preference ?? "system";
        Refresh();
    }

    internal static void Refresh()
    {
        string next = Resolve(_preference, IsDark("AppsUseLightTheme"));
        bool taskbar = IsDark("SystemUsesLightTheme");
        bool changed = Current != next || TaskbarDark != taskbar;
        Current = next;
        TaskbarDark = taskbar;
        if (changed) Changed?.Invoke();
    }

    private static bool IsDark(string name)
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(Personalize, writable: false);
            return key?.GetValue(name) is int value && value == 0;
        }
        catch (Exception) { return false; }
    }
}
