using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace AISubGauge;

internal sealed class RunningProcesses
{
    internal const int PollIntervalMilliseconds = 5000;
    private readonly IReadOnlyDictionary<string, string[]> _mapping;

    internal RunningProcesses(string? settingsDirectory = null)
    {
        using Stream resource = SharedResources.Open("running-processes.json");
        var defaults = JsonSerializer.Deserialize<Dictionary<string, string[]>>(resource)!;
        string path = Path.Combine(settingsDirectory ?? AppSettings.SettingsDirectory, "running-processes.json");
        try
        {
            if (File.Exists(path))
            {
                using FileStream file = LocalFiles.OpenRead(path, 1024 * 1024);
                var custom = JsonSerializer.Deserialize<Dictionary<string, string[]>>(file);
                if (custom is not null && custom.All(pair => pair.Value is not null && pair.Value.All(name => !string.IsNullOrWhiteSpace(name))))
                    defaults = custom;
            }
        }
        catch (Exception) { } // An unreadable/invalid override falls back to the bundled mapping.
        _mapping = defaults;
    }

    internal Dictionary<string, bool> Detect() => Match(ReadNames());
    internal Dictionary<string, bool> Match(IEnumerable<string> names) => Match(_mapping, names);

    internal static Dictionary<string, bool> Match(IReadOnlyDictionary<string, string[]> mapping, IEnumerable<string> names)
    {
        var running = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
        return ProviderRegistry.CreateEnabled().ToDictionary(provider => provider.Id,
            provider => mapping.TryGetValue(provider.Id, out string[]? aliases) && aliases.Any(running.Contains), StringComparer.Ordinal);
    }

    private static IEnumerable<string> ReadNames()
    {
        // ProcessName is the Windows image name without .exe. Never inspect arguments, modules or memory.
        var names = new List<string>();
        foreach (Process process in Process.GetProcesses())
        {
            using (process)
            {
                try { names.Add(process.ProcessName); }
                catch (InvalidOperationException) { } // The process exited between enumeration and lookup.
                catch (System.ComponentModel.Win32Exception) { }
            }
        }
        return names;
    }
}

// All time comes from the caller. A provider that has never run gets no startup grace period.
internal sealed class RunningVisibility
{
    internal static readonly TimeSpan GracePeriod = TimeSpan.FromSeconds(30);
    private readonly Dictionary<string, DateTimeOffset?> _stoppedAt = new(StringComparer.Ordinal);

    internal HashSet<string> Update(DateTimeOffset now, IReadOnlyDictionary<string, bool> running)
    {
        var visible = new HashSet<string>(StringComparer.Ordinal);
        foreach (var pair in running)
        {
            if (pair.Value)
            {
                _stoppedAt[pair.Key] = null;
                visible.Add(pair.Key);
            }
            else if (_stoppedAt.TryGetValue(pair.Key, out DateTimeOffset? stopped))
            {
                stopped ??= now;
                _stoppedAt[pair.Key] = stopped;
                if (now - stopped.Value < GracePeriod) visible.Add(pair.Key);
            }
        }
        return visible;
    }

    internal static ProviderDisplay Select(IEnumerable<string> selected, IReadOnlySet<string> running, bool alwaysShowAll)
    {
        var visible = new HashSet<string>(selected.Where(id => alwaysShowAll || running.Contains(id)), StringComparer.Ordinal);
        return new ProviderDisplay(visible);
    }
}

internal sealed record ProviderDisplay(IReadOnlySet<string> Providers)
{
    internal bool ShowIdle => Providers.Count == 0;
}
