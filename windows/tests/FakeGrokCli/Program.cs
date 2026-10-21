using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

internal static class Program
{
    private static async Task Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "codex-tree-test")
        {
            var childInfo = new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!)
            {
                UseShellExecute = false, CreateNoWindow = true
            };
            childInfo.ArgumentList.Add("codex-test");
            childInfo.ArgumentList.Add(args[1] + ".child");
            childInfo.ArgumentList.Add("child");
            using System.Diagnostics.Process child = System.Diagnostics.Process.Start(childInfo)!;
            await RunCodexAsync(args[1]);
            return;
        }
        if (args.Length is 2 or 3 && args[0] == "codex-test")
        {
            await RunCodexAsync(args[1], child: args.Length == 3);
            return;
        }
        if (args.Length != 2 || args[0] != "agent" || args[1] != "stdio") return;
        string home = Environment.GetEnvironmentVariable("GROK_HOME") ?? throw new InvalidOperationException();
        string path = Environment.GetEnvironmentVariable("GROK_AUTH_PATH") ?? throw new InvalidOperationException();
        string mode = File.ReadAllText(Path.Combine(home, "test-mode"));
        string secret = "sk-test-SENTINEL-DO-NOT-EXPOSE-1234567890";
        string[] allowed = { "SystemRoot", "windir", "TEMP", "TMP", "USERPROFILE", "HOME", "LOCALAPPDATA", "APPDATA",
            "PATH", "GROK_HOME", "GROK_AUTH_PATH", "GROK_LOG_FILE", "RUST_LOG", "GROK_TELEMETRY_ENABLED", "GROK_EXTERNAL_OTEL",
            "ComSpec", "PATHEXT", "PROCESSOR_ARCHITECTURE" };
        var names = new HashSet<string>(allowed, StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry item in Environment.GetEnvironmentVariables())
            if (item.Key is string name && !names.Contains(name)) mode = "failure";
        if (Environment.GetEnvironmentVariable("GROK_LOG_FILE") != "NUL" ||
            Environment.GetEnvironmentVariable("RUST_LOG") != "off" ||
            Environment.GetEnvironmentVariable("GROK_TELEMETRY_ENABLED") != "0" ||
            Environment.GetEnvironmentVariable("GROK_EXTERNAL_OTEL") != "0") mode = "failure";
        // SelfTestAsync must create a protected home even when %TEMP% grants foreign Modify ACEs.
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        DirectorySecurity homeSecurity = new DirectoryInfo(home).GetAccessControl();
        if (!homeSecurity.AreAccessRulesProtected || !Equals(homeSecurity.GetOwner(typeof(SecurityIdentifier)), identity.User))
            mode = "failure";
        while (await Console.In.ReadLineAsync() is string line)
        {
            using JsonDocument request = JsonDocument.Parse(line);
            int id = request.RootElement.GetProperty("id").GetInt32();
            string? method = request.RootElement.GetProperty("method").GetString();
            if (method == "initialize")
            {
                await Console.Out.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result = new { protocolVersion = 1 } }));
                continue;
            }
            if (method != "_x.ai/auth/getBearerToken") return;
            await Console.Error.WriteLineAsync(secret); // The parent must discard all stderr.
            if (mode == "timeout") { await Task.Delay(TimeSpan.FromSeconds(60)); return; }
            if (mode == "oversize") { await Console.Out.WriteAsync(new string('x', 1_048_577)); await Console.Out.FlushAsync(); return; }
            if (mode == "early-exit") return;
            if (mode == "failure")
            {
                await Console.Out.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, error = new { code = -1, message = secret } }));
                return;
            }
            JsonObject auth = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
            JsonObject credential = auth["https://auth.x.ai::test-client"]!.AsObject();
            credential["key"] = secret;
            credential["create_time"] = DateTimeOffset.UtcNow.ToString("O");
            credential["expires_at"] = DateTimeOffset.UtcNow.AddDays(30).ToString("O");
            if (mode == "wrong-user") credential["user_id"] = "other-user";
            if (mode == "wrong-client") credential["oidc_client_id"] = "other-client";
            if (mode == "still-expired") credential["expires_at"] = DateTimeOffset.UtcNow.AddDays(-1).ToString("O");
            File.WriteAllText(path, auth.ToJsonString()); // Only this CLI fixture changes the synthetic credential bytes.
            if (mode == "wide-acl")
            {
                FileSecurity security = new FileInfo(path).GetAccessControl();
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
                    FileSystemRights.Read, AccessControlType.Allow));
                new FileInfo(path).SetAccessControl(security);
            }
            await Console.Out.WriteLineAsync(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result = new { bearerToken = secret } }));
            await Console.Out.FlushAsync();
            await Task.Delay(TimeSpan.FromSeconds(60)); // The parent must kill this tree and finish with bounded waits.
        }
    }

    private static async Task RunCodexAsync(string startedPath, bool child = false)
    {
        // Publish readiness atomically. Children stay alive independently of the parent's stdio/exit.
        File.WriteAllText(startedPath + ".tmp", Environment.ProcessId.ToString());
        File.Move(startedPath + ".tmp", startedPath);
        if (child)
        {
            await Task.Delay(System.Threading.Timeout.Infinite);
            return;
        }
        while (!File.Exists(Path.Combine(Path.GetDirectoryName(startedPath)!, "cli-continue")))
            await Task.Delay(25);
        while (await Console.In.ReadLineAsync() is string line)
        {
            using JsonDocument request = JsonDocument.Parse(line);
            if (!request.RootElement.TryGetProperty("id", out JsonElement id)) continue;
            string? method = request.RootElement.GetProperty("method").GetString();
            object result = method switch
            {
                "initialize" => new { },
                "account/read" => new { account = new { type = "chatgpt", planType = "synthetic-test" } },
                "account/rateLimits/read" => new { rateLimits = new { primary = new { usedPercent = 25, windowDurationMins = 300 } } },
                _ => throw new InvalidOperationException()
            };
            await Console.Out.WriteLineAsync(JsonSerializer.Serialize(new { id = id.GetInt32(), result }));
            await Console.Out.FlushAsync();
            if (method == "account/rateLimits/read") return;
        }
    }
}
