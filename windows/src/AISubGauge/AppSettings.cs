using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AISubGauge;

internal sealed class AppSettings
{
    public Dictionary<string, bool?> ProviderVisibility { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, bool> ProviderConsent { get; set; } = new(StringComparer.Ordinal);
    public bool? LaunchAtLogin { get; set; }
    public bool AlwaysShowAll { get; set; }
    public string Language { get; set; } = "system";
    public string Theme { get; set; } = "system";
    internal static string SettingsDirectory => Environment.GetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR") is string directory
        ? LocalFiles.FullPath(directory)
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AISubGauge");
    [JsonIgnore] internal string SettingsPath { get; private set; } = Path.Combine(SettingsDirectory, "settings.json");
    private bool _saveEnabled = true;

    internal static AppSettings ForDemo() => new() { _saveEnabled = false };

    public bool HasConsent(string id) => ProviderConsent.TryGetValue(id, out bool value) && value;
    public bool NeedsConsent(string id) => !ProviderConsent.ContainsKey(id);
    public bool IsVisible(string id, bool signedIn, bool demo) => demo ||
        (ProviderVisibility.TryGetValue(id, out bool? value) && value.HasValue ? value.Value : signedIn);

    public bool Save()
    {
        if (!_saveEnabled) return true;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            string temporary = SettingsPath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, SettingsPath, overwrite: true);
            return true;
        }
        catch (Exception) { return false; }
    }

    public static AppSettings Load(string? localAppData = null, bool migrate = true)
    {
        string root = localAppData ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string directory = localAppData is null ? SettingsDirectory : Path.Combine(root, "AISubGauge");
        string path = Path.Combine(directory, "settings.json");
        string legacy = Path.Combine(localAppData is null && Environment.GetEnvironmentVariable("AISUBGAUGE_SETTINGS_DIR") is not null
            ? directory : root, "WindowsQuotaTray", "settings.json");
        var fallback = new AppSettings { SettingsPath = path };
        try
        {
            bool migrated = !File.Exists(path) && File.Exists(legacy);
            string source = migrated ? legacy : path;
            if (!File.Exists(source)) return fallback;
            // Bound while reading, before migration copies anything or JSON parsing allocates.
            using FileStream file = LocalFiles.OpenRead(source, SharedResources.MaxBytes);
            byte[] bytes = SharedResources.ReadBounded(file);
            if (migrated && migrate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                using FileStream output = new(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                output.Write(bytes); // Keep unknown legacy fields without overwriting a concurrently created file.
            }
            AppSettings settings = JsonSerializer.Deserialize<AppSettings>(bytes) ?? fallback;
            settings.SettingsPath = path;
            settings.ProviderVisibility ??= new(StringComparer.Ordinal);
            settings.ProviderConsent ??= new(StringComparer.Ordinal);
            if (settings.Language is not ("en" or "zh-Hans")) settings.Language = "system";
            if (settings.Theme is not ("light" or "dark")) settings.Theme = "system";
            // Visibility never implies consent. Missing entries remain pending for the per-provider prompt.
            return settings;
        }
        catch (Exception) { return fallback; } // Preserve unreadable/corrupt files; expose no raw exception.
    }
}
