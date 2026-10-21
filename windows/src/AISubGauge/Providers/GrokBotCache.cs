using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

internal static class GrokBotCache
{
    public static bool IsSignedInLocally()
    {
        foreach (Environment.SpecialFolder root in new[] { Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData })
            if (LocalFiles.Exists(Path.Combine(Environment.GetFolderPath(root), "Grok Bot", "sand-client-persistence",
                    Filename("sand.client.slice.client-meta.account-slot"))))
                return true;
        return false;
    }

    public static async Task<QuotaSnapshot> ReadAsync(GrokProvider provider, CancellationToken cancellationToken)
    {
        foreach (Environment.SpecialFolder root in new[] { Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData })
        {
            string directory = Path.Combine(Environment.GetFolderPath(root), "Grok Bot", "sand-client-persistence");
            string markerPath = Path.Combine(directory, Filename("sand.client.slice.client-meta.account-slot"));
            if (!LocalFiles.Exists(markerPath)) continue;
            using JsonDocument marker = await ReadObjectAsync(markerPath, cancellationToken).ConfigureAwait(false);
            if (!QuotaJson.TryNumber(marker.RootElement, "schemaVersion", out double schema) || schema != 1)
                throw new QuotaReadException(I18n.Get("windows.the.grok.bot.current.account.marker.format.is.unsupported"));
            string? slot = QuotaJson.String(marker.RootElement, "value");
            if (string.IsNullOrEmpty(slot) || Encoding.UTF8.GetByteCount(slot) > 512)
                throw new QuotaReadException(I18n.Get("windows.the.current.grok.bot.account.is.not.signed.in.or"));
            // Match JavaScript encodeURIComponent / the Mac cache key, including these five characters.
            string escaped = Uri.EscapeDataString(slot).Replace("%21", "!").Replace("%2A", "*").Replace("%27", "'")
                .Replace("%28", "(").Replace("%29", ")");
            string cachePath = Path.Combine(directory, Filename("sand.client.slice.account." + escaped + ".weekly-usage.cache"));
            using JsonDocument cache = await ReadObjectAsync(cachePath, cancellationToken).ConfigureAwait(false);
            return Parse(provider, cache.RootElement);
        }
        throw new QuotaReadException(I18n.Get("windows.no.official.grok.login.or.local.grok.bot.usage.cache"));
    }

    private static QuotaSnapshot Parse(GrokProvider provider, JsonElement root)
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        if (!QuotaJson.TryNumber(root, "schemaVersion", out double schema) || schema != 2 ||
            !QuotaJson.TryProperty(root, "value", out JsonElement value) || QuotaJson.String(value, "kind") != "present" ||
            !QuotaJson.TryProperty(value, "reading", out JsonElement reading) ||
            !QuotaJson.TryProperty(reading, "usage", out JsonElement usage) ||
            !QuotaJson.TryNumber(usage, "percentUsed", out double used) || used < 0 ||
            Milliseconds(reading, "readAtMs") is not DateTimeOffset readAt || readAt > now.AddMinutes(5) ||
            Milliseconds(value, "expiresAtMs") is not DateTimeOffset expiresAt || expiresAt < readAt)
            throw new QuotaReadException(I18n.Get("windows.the.grok.bot.usage.cache.is.not.ready.or.has"));
        bool included = QuotaJson.TryProperty(usage, "hasNonZeroIncludedLimit", out JsonElement includedFlag) && includedFlag.ValueKind == JsonValueKind.True;
        bool team = QuotaJson.TryProperty(usage, "isTeamSeat", out JsonElement teamFlag) && teamFlag.ValueKind == JsonValueKind.True;
        var windows = new List<QuotaWindow>
        {
            new() { Id = "grok.weekly", Title = team ? I18n.Get("usage.team.weekly") : I18n.Get("quota.weekly"), RemainingPercent = included ? Math.Clamp(100 - used, 0, 100) : null,
                ResetsAt = Milliseconds(usage, "nextResetMs") }
        };
        if (QuotaJson.TryProperty(usage, "onDemand", out JsonElement additional) &&
            QuotaJson.TryNumber(additional, "usedCents", out double spent) && spent >= 0 &&
            QuotaJson.TryNumber(additional, "limitCents", out double limit) && limit > 0)
            windows.Add(new QuotaWindow { Id = "grok.additional", Title = I18n.Get("usage.extra.usage.limit"),
                RemainingPercent = Math.Clamp(100 - spent / limit * 100, 0, 100) });
        string? plan = QuotaJson.String(usage, "grokPlanLabel");
        return new QuotaSnapshot
        {
            Provider = provider, Plan = string.IsNullOrWhiteSpace(plan) ? I18n.Get("windows.unknown.plan") : plan, Windows = windows, UpdatedAt = readAt.LocalDateTime,
            IsStale = now >= expiresAt,
            Info = I18n.Get("windows.grok.bot.official.local.usage.cache.read.only") +
                (now >= expiresAt ? I18n.Get("usage.the.cache.has.expired.open.account.usage") : I18n.Get("windows.loaded.the.most.recently.written.cache")) +
                I18n.Get("windows.shared.account.quota.specific.model.settings.were.not.provided")
        };
    }

    private static DateTimeOffset? Milliseconds(JsonElement value, string name) =>
        QuotaJson.TryNumber(value, name, out double milliseconds) && milliseconds > 0 && milliseconds <= 253_402_300_799_000d
            ? DateTimeOffset.UnixEpoch.AddMilliseconds(milliseconds) : null;

    private static async Task<JsonDocument> ReadObjectAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            return await CredentialFiles.ReadAsync(path, cancellationToken, 256_000).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (QuotaReadException) { throw; }
        catch (Exception) { throw new QuotaReadException(I18n.Get("windows.the.current.grok.bot.account.s.usage.cache.cannot.be")); }
    }

    private static string Filename(string key)
    {
        const string alphabet = "abcdefghijklmnopqrstuvwxyz234567";
        var result = new StringBuilder();
        int buffer = 0;
        int bits = 0;
        foreach (byte value in Encoding.UTF8.GetBytes(key))
        {
            buffer = (buffer << 8) | value;
            bits += 8;
            while (bits >= 5)
            {
                bits -= 5;
                result.Append(alphabet[(buffer >> bits) & 31]);
            }
            buffer &= (1 << bits) - 1;
        }
        if (bits > 0) result.Append(alphabet[(buffer << (5 - bits)) & 31]);
        return result.ToString() + ".blob";
    }
}
