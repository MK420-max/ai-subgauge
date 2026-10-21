using System;
using System.IO;
using System.Linq;
using AISubGauge.Providers;
using Xunit;

namespace AISubGauge.Tests;

public sealed class CodexExecutableTests
{
    [Fact]
    public void DiscoveryUsesOnlyOfficialRootsIncludingNestedAppHashesAndNpmVendorBinaries()
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        string local = Path.Combine(root, "local"), roaming = Path.Combine(root, "roaming");
        string[] expected =
        {
            Path.Combine(local, "OpenAI", "Codex", "bin", "codex.exe"),
            Path.Combine(local, "OpenAI", "Codex", "bin", "hash", "nested", "codex.exe"),
            Path.Combine(roaming, "npm", "node_modules", "@openai", "codex", "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe")
        };
        foreach (string path in expected)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "unsigned fixture; never executed");
        }
        string? previous = Environment.GetEnvironmentVariable("PATH");
        try
        {
            File.WriteAllText(Path.Combine(root, "codex.exe"), "PATH fixture; never executed");
            Environment.SetEnvironmentVariable("PATH", root);
            Assert.Equal(expected.OrderBy(path => path), CodexProvider.FindCandidates(null, local, roaming).OrderBy(path => path));
            Assert.Empty(CodexProvider.FindCandidates(null, Path.Combine(root, "absent-local"), Path.Combine(root, "absent-roaming")));
        }
        finally { Environment.SetEnvironmentVariable("PATH", previous); }
    }

    [Theory]
    [InlineData(@".\codex.exe")]
    [InlineData(@"\\server\share\codex.exe")]
    [InlineData(@"C:\codex.cmd")]
    public void InvalidOverrideIsRejectedWithoutFallback(string configured)
    {
        string? previous = Environment.GetEnvironmentVariable("CODEX_EXE");
        try
        {
            Environment.SetEnvironmentVariable("CODEX_EXE", configured);
            Assert.Throws<QuotaReadException>(() => CodexProvider.FindExecutable());
            Assert.Equal(new[] { configured }, CodexProvider.FindCandidates(configured, "unused", "unused"));
        }
        finally { Environment.SetEnvironmentVariable("CODEX_EXE", previous); }
    }

    [Fact]
    public void UnsignedOverrideIsRefusedWithAnExplicitSignatureMessage()
    {
        string? previous = Environment.GetEnvironmentVariable("CODEX_EXE");
        try
        {
            string unsigned = Path.Combine(AppContext.BaseDirectory, "FakeGrokCli", "FakeGrokCli.exe");
            Environment.SetEnvironmentVariable("CODEX_EXE", unsigned);
            var error = Assert.Throws<QuotaReadException>(() => CodexProvider.FindExecutable());
            Assert.Equal(I18n.Get("windows.codex.signatureRequired"), error.Message);
            using FileStream file = LocalFiles.OpenRead(unsigned, long.MaxValue);
            Assert.Throws<QuotaReadException>(() => Authenticode.ValidateCodex(unsigned, file));
        }
        finally { Environment.SetEnvironmentVariable("CODEX_EXE", previous); }
    }
}
