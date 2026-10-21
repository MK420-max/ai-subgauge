using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace AISubGauge;

internal static class I18n
{
    private static readonly Dictionary<string, string> English = Load("en");
    private static Dictionary<string, string> _strings = Load(ResolveLanguage(null));
    internal static string Language { get; private set; } = ResolveLanguage(null);
    internal static CultureInfo Culture => CultureInfo.GetCultureInfo(Language);

    internal static string ResolveLanguage(string? preference, string? systemLanguage = null) =>
        preference is "en" or "zh-Hans" ? preference :
        (systemLanguage ?? CultureInfo.CurrentUICulture.Name).StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en";

    internal static void Initialize(string? preference)
    {
        Language = ResolveLanguage(preference);
        _strings = Load(Language);
    }

    internal static Dictionary<string, string> Load(string language)
    {
        try
        {
            using Stream stream = SharedResources.Open("i18n." + language + ".json");
            return Load(stream);
        }
        catch (Exception) { return Defaults(); }
    }

    internal static Dictionary<string, string> Load(Stream stream)
    {
        try
        {
            var strings = JsonSerializer.Deserialize<Dictionary<string, string>>(SharedResources.ReadBounded(stream));
            if (strings is null || strings.Any(entry => string.IsNullOrWhiteSpace(entry.Value))) return Defaults();
            return strings;
        }
        catch (Exception) { return Defaults(); }
    }

    private static Dictionary<string, string> Defaults() => new(StringComparer.Ordinal)
    {
        ["app.name"] = "AI SubGauge",
        ["common.cancel"] = "Cancel",
        ["windows.quit"] = "Quit",
        ["windows.operation.failed.check.local.paths.file.and.registry.permissions.output"] = "Operation failed. Check local paths and permissions."
    };

    internal static string Get(string key, params object?[] values)
    {
        if (!_strings.TryGetValue(key, out string? text) && !English.TryGetValue(key, out text)) text = key;
        try { return values.Length == 0 ? text : string.Format(Culture, text, values); }
        catch (FormatException) { return key; }
    }
}
