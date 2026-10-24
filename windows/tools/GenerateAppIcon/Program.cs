using System.Drawing;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length != 1) throw new ArgumentException("An output icon path is required.");
        string output = Path.GetFullPath(args[0]);
        string assetDirectory = Path.GetDirectoryName(output)!;
        int[] sizes = [16, 20, 24, 32, 40, 48, 64, 256];
        // Package each reviewed native PNG verbatim; no rendering or upscaling.
        byte[][] frames = sizes.Select(size =>
        {
            byte[] png = File.ReadAllBytes(Path.Combine(assetDirectory, "brand", $"app-light-win-{size}.png"));
            using var stream = new MemoryStream(png);
            using var bitmap = new Bitmap(stream);
            if (bitmap.Width != size || bitmap.Height != size) throw new InvalidDataException("App icon frame dimensions do not match.");
            return png;
        }).ToArray();
        using var icon = new MemoryStream();
        using var writer = new BinaryWriter(icon);
        writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
        int offset = 6 + 16 * sizes.Length;
        for (int i = 0; i < sizes.Length; i++)
        {
            byte dimension = sizes[i] == 256 ? (byte)0 : (byte)sizes[i];
            writer.Write(dimension); writer.Write(dimension); writer.Write((byte)0); writer.Write((byte)0);
            writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(frames[i].Length); writer.Write(offset);
            offset += frames[i].Length;
        }
        foreach (byte[] frame in frames) writer.Write(frame);
        File.WriteAllBytes(output, icon.ToArray());
    }
}
