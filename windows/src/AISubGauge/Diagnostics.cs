using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using AISubGauge.Providers;

namespace AISubGauge;

internal static class Diagnostics
{
    // Redact before both preview and save. No credential object or raw exception enters this text.
    public static string Create(IReadOnlyList<QuotaSnapshot> snapshots)
    {
        var text = new StringBuilder();
        text.AppendLine(I18n.Get("windows.diagnostics.title", "1.2.0"));
        text.AppendLine(I18n.Get("windows.diagnostics.os", Environment.OSVersion.VersionString));
        foreach (IQuotaProvider provider in ProviderRegistry.CreateEnabled())
        {
            QuotaSnapshot? snapshot = snapshots.FirstOrDefault(item => item.Provider.Id == provider.Id);
            if (snapshot is null) { text.AppendLine(provider.DisplayName + I18n.Get("windows.hidden.or.not.refreshed.yet")); continue; }
            text.AppendLine(I18n.Get("windows.diagnostics.entry", provider.DisplayName, snapshot.IsDemo ? I18n.Get("demo.label") : snapshot.Error is not null ? I18n.Get("status.refreshFailed") : I18n.Get("status.connected"), snapshot.Error ?? I18n.Get("windows.no.errors")));
        }
        return Redact(text.ToString());
    }

    internal static string Redact(string text, string? machineName = null)
    {
        const RegexOptions flags = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
        TimeSpan timeout = TimeSpan.FromSeconds(1);
        string value = Regex.Replace(text, @"\bC:[\\/]Users[\\/][^\\/\r\n""<>]+", @"C:\Users\<user>", flags, timeout);
        value = Regex.Replace(value, @"\b(?:ssid|wi-?fi(?:name)?|(?:weather)?latitude|(?:weather)?longitude|coordinates?|weathercity)\s*[""']?\s*[:=]\s*(?:""[^""]*""|'[^']*'|\[[^\]]*\]|[^\r\n,;}]+)", "<location>", flags, timeout);
        value = Regex.Replace(value, @"(?<![\w.])-?\d{1,2}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}(?![\w.])", "<coordinates>", flags, timeout);
        value = Regex.Replace(value, @"[\w.!#$%&'*+/=?^`{|}~-]+@[\w-]+(?:\.[\w-]+)+", "<email>", flags, timeout);
        value = Regex.Replace(value, @"\b(?:Bearer|token|access_token|refresh_token|api[_-]?key)\s*[""']?\s*[:=]?\s*[""']?\s+[A-Za-z0-9_./+\-=]{8,}", "<token>", flags, timeout);
        value = Regex.Replace(value, @"\b(?:sk-(?:ant-)?|xai-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]{8,}|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|\b[A-Za-z0-9_+/=-]{32,}\b", "<token>", flags, timeout);
        value = Regex.Replace(value, @"\b(?:access_token|refresh_token|token|api[_-]?key)[""']?\s*[:=]\s*[""']?[^\s""',;}]+", "<token>", flags, timeout);
        string machine = machineName ?? Environment.MachineName;
        if (!string.IsNullOrEmpty(machine))
            value = Regex.Replace(value, Regex.Escape(machine), "<machine>", flags, timeout);
        return value;
    }
}
