using System.Text;
using System.Text.Json;

namespace AISubGauge.Core;

public sealed class CredentialFiles(IClock clock) : ICredentialSource
{
    private static string UserFile(params string[] parts) => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.Combine(parts));
    public static string GrokPath => Environment.GetEnvironmentVariable("GROK_AUTH_PATH") ?? Path.Combine(Environment.GetEnvironmentVariable("GROK_HOME") ?? UserFile(".grok"), "auth.json");
    public async Task<Credential?> ReadAsync(Vendor vendor, CancellationToken cancellation)
    {
        if (vendor == Vendor.Claude)
        {
            string? token = Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN");
            if (!string.IsNullOrWhiteSpace(token)) return new(token.Trim());
            using var document = await ReadFileAsync(UserFile(".claude", ".credentials.json"), cancellation).ConfigureAwait(false);
            var oauth = Json.Get(document.RootElement, "claudeAiOauth");
            token = Json.String(oauth, "accessToken");
            if (string.IsNullOrEmpty(token)) throw new SafeFailure(Fault.SignIn);
            return new(token, plan: Presentation.ParsePlan(Json.String(oauth, "subscriptionType")));
        }
        if (vendor != Vendor.Grok) return null;
        if (!File.Exists(GrokPath)) return null;
        using var auth = await ReadFileAsync(GrokPath, cancellation).ConfigureAwait(false);
        if (auth.RootElement.ValueKind != JsonValueKind.Object) throw new SafeFailure(Fault.InvalidData);
        Credential? selected = null;
        foreach (var entry in auth.RootElement.EnumerateObject())
        {
            var value = entry.Value;
            if (Json.String(value, "auth_mode") is not ("oidc" or "external") || Json.String(value, "oidc_issuer") is not ("https://auth.x.ai" or "https://auth.x.ai/")) continue;
            string? client = Json.String(value, "oidc_client_id"), token = Json.String(value, "key"), user = Json.String(value, "user_id");
            var created = Json.Date(value, "create_time");
            if (!Header(token, 32768) || !Header(user, 256) || !Header(client, 256) || entry.Name != "https://auth.x.ai::" + client || created is null || created > clock.Now.AddMinutes(5)) throw new SafeFailure(Fault.SignIn);
            var expiry = Json.Date(value, "expires_at");
            if (Json.Get(value, "expires_at").ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null) && expiry is null) throw new SafeFailure(Fault.InvalidData);
            var next = new Credential(token!, user!, client!, expiry ?? created.Value.AddDays(30));
            if (selected is not null && selected.UserId != next.UserId) throw new SafeFailure(Fault.SignIn);
            if (selected is null || next.Expires > selected.Expires) selected = next;
        }
        return selected ?? throw new SafeFailure(Fault.SignIn);
    }
    private static bool Header(string? value, int max) => !string.IsNullOrEmpty(value) && value.Length <= max && value.All(c => c >= 0x21 && c <= 0x7e);
    internal static async Task<JsonDocument> ReadFileAsync(string path, CancellationToken cancellation)
    {
        await using var file = LocalFiles.OpenRead(path, 1048576);
        return await Json.ReadAsync(file, cancellation).ConfigureAwait(false);
    }
}
public sealed class GrokBotCache(IClock clock) : IGrokCache
{
    public async Task<Snapshot> ReadAsync(CancellationToken cancellation)
    {
        foreach (var special in new[] { Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData })
        {
            string directory = Path.Combine(Environment.GetFolderPath(special), "Grok Bot", "sand-client-persistence");
            string marker = Path.Combine(directory, Filename("sand.client.slice.client-meta.account-slot"));
            if (!File.Exists(marker)) continue;
            using var account = await CredentialFiles.ReadFileAsync(marker, cancellation).ConfigureAwait(false);
            string? slot = Json.String(account.RootElement, "value");
            if (Json.Number(account.RootElement, "schemaVersion") != 1 || string.IsNullOrEmpty(slot) || slot.Length > 512) throw new SafeFailure(Fault.InvalidData);
            string escaped = Uri.EscapeDataString(slot).Replace("%21", "!").Replace("%2A", "*").Replace("%27", "'").Replace("%28", "(").Replace("%29", ")");
            using var cache = await CredentialFiles.ReadFileAsync(Path.Combine(directory, Filename("sand.client.slice.account." + escaped + ".weekly-usage.cache")), cancellation).ConfigureAwait(false);
            return Parse(cache.RootElement);
        }
        throw new SafeFailure(Fault.SignIn);
    }
    public Snapshot Parse(JsonElement root)
    {
        var value = Json.Get(root, "value"); var reading = Json.Get(value, "reading"); var usage = Json.Get(reading, "usage");
        var readAt = Millis(reading, "readAtMs"); var expires = Millis(value, "expiresAtMs"); var used = Json.Number(usage, "percentUsed");
        if (Json.Number(root, "schemaVersion") != 2 || Json.String(value, "kind") != "present" || used is null || used < 0 || readAt is null || readAt > clock.Now.AddMinutes(5) || expires is null || expires < readAt) throw new SafeFailure(Fault.InvalidData);
        if (expires <= clock.Now) return Snapshot.Failure(Vendor.Grok, Fault.CacheExpired, clock);
        bool included = Json.Get(usage, "hasNonZeroIncludedLimit").ValueKind == JsonValueKind.True;
        return new(Vendor.Grok, Presentation.ParsePlan(Json.String(usage, "grokPlanLabel")), new(),
            new(included ? Math.Clamp(100 - used.Value, 0, 100) : null, Millis(usage, "nextResetMs")), readAt.Value);
    }
    private static DateTimeOffset? Millis(JsonElement root, string name) => Json.Number(root, name) is double n && n >= 0 && n <= 253402300799999 ? DateTimeOffset.FromUnixTimeMilliseconds((long)n) : null;
    public static string Filename(string key)
    {
        const string alphabet = "abcdefghijklmnopqrstuvwxyz234567";
        var output = new StringBuilder(); int buffer = 0, bits = 0;
        foreach (byte b in Encoding.UTF8.GetBytes(key))
        {
            buffer = (buffer << 8) | b; bits += 8;
            while (bits >= 5) { bits -= 5; output.Append(alphabet[(buffer >> bits) & 31]); }
            buffer &= (1 << bits) - 1;
        }
        if (bits > 0) output.Append(alphabet[(buffer << (5 - bits)) & 31]);
        return output + ".blob";
    }
}
