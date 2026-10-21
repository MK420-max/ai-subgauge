using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

internal static class CredentialFiles
{
    public static string UserFile(params string[] parts) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.Combine(parts));

    public static string CodexPath => Path.Combine(ConfiguredHome("CODEX_HOME", ".codex"), "auth.json");
    public static string GrokPath => Path.Combine(ConfiguredHome("GROK_HOME", ".grok"), "auth.json");
    public static string ClaudePath => UserFile(".claude", ".credentials.json");
    public static string GeminiPath => UserFile(".gemini", "oauth_creds.json");
    public static string KimiPath => UserFile(".kimi-code", "credentials", "kimi-code.json");
    public static string CopilotPath(string name) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "github-copilot", name);

    private static string ConfiguredHome(string variable, string fallback) =>
        Environment.GetEnvironmentVariable(variable) is string home && !string.IsNullOrWhiteSpace(home) ? home : UserFile(fallback);

    public static async Task<JsonDocument> ReadAsync(string path, CancellationToken cancellationToken, int maximum = 1_048_576)
    {
        await using FileStream file = LocalFiles.OpenRead(path, maximum);
        CredentialAccess.Validate(file);
        byte[] bytes = await GrokProvider.ReadBoundedAsync(file, maximum, cancellationToken).ConfigureAwait(false);
        return JsonDocument.Parse(bytes);
    }

    public static bool IsProtectedPath(string path)
    {
        foreach (string candidate in ProtectedPaths())
        {
            try
            {
                if (LocalFiles.FullPath(candidate).Equals(path, StringComparison.OrdinalIgnoreCase)) return true;
            }
            catch (IOException) { } // An invalid configured path cannot be a local output target.
            catch (ArgumentException) { }
        }
        return false;
    }

    private static IEnumerable<string> ProtectedPaths()
    {
        yield return CodexPath;
        yield return UserFile(".codex", "auth.json");
        yield return GrokPath;
        yield return UserFile(".grok", "auth.json");
        if (Environment.GetEnvironmentVariable("GROK_AUTH_PATH") is string grok && !string.IsNullOrWhiteSpace(grok)) yield return grok;
        yield return ClaudePath;
        yield return GeminiPath;
        yield return CopilotPath("apps.json");
        yield return CopilotPath("hosts.json");
        yield return KimiPath;
    }
}
