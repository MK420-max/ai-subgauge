using System;
using System.IO;

namespace AISubGauge;

internal static class SharedResources
{
    internal const int MaxBytes = 1_048_576;

    internal static Stream Open(string name) => typeof(SharedResources).Assembly.GetManifestResourceStream(
        "AISubGauge.shared." + name) ?? throw new InvalidOperationException(name);

    internal static byte[] ReadBounded(Stream stream)
    {
        using var output = new MemoryStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = stream.Read(buffer, 0, Math.Min(buffer.Length, MaxBytes + 1 - (int)output.Length))) != 0)
        {
            output.Write(buffer, 0, count);
            if (output.Length > MaxBytes) throw new InvalidDataException("Shared resource exceeds 1 MiB.");
        }
        return output.ToArray();
    }
}
