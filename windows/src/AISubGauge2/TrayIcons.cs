using AISubGauge.Core;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace AISubGauge.UI;

// One independently rendered PNG per ICO entry. No master bitmap is resized to build the family.
public sealed class TrayIconFamily
{
    public static IReadOnlyList<int> Sizes { get; } = Array.AsReadOnly(new[] { 16, 20, 24, 32, 40, 48, 64 });
    private readonly byte[][] frames;

    public TrayIconFamily(Vendor vendor, double? percent, bool dark, bool showPercentage = false)
    {
        frames = Sizes.Select(size =>
        {
            using var bitmap = RingIcon.TrayBitmap(vendor, percent, dark, size, showPercentage);
            using var png = new MemoryStream(); bitmap.Save(png, ImageFormat.Png); return png.ToArray();
        }).ToArray();
    }

    public byte[] ToIco()
    {
        using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream);
        writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)Sizes.Count);
        int offset = 6 + 16 * Sizes.Count;
        for (int i = 0; i < Sizes.Count; i++)
        {
            writer.Write((byte)Sizes[i]); writer.Write((byte)Sizes[i]); writer.Write((byte)0); writer.Write((byte)0);
            writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(frames[i].Length); writer.Write(offset);
            offset += frames[i].Length;
        }
        foreach (var frame in frames) writer.Write(frame);
        return stream.ToArray();
    }

    public void Save(string path) => File.WriteAllBytes(path, ToIco());

    public static int BestSize(int requestedSize)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(requestedSize);
        // Like LoadIconWithScaleDown: exact match, otherwise smallest larger image, largest as last resort.
        return Sizes.FirstOrDefault(size => size >= requestedSize, Sizes[^1]);
    }

    public Icon CreateIcon(int requestedSize)
    {
        int selected = BestSize(requestedSize);
        var png = frames[Sizes.ToList().IndexOf(selected)];
        var handle = CreateIconFromResourceEx(png, (uint)png.Length, true, 0x00030000, requestedSize, requestedSize, 0);
        if (handle == IntPtr.Zero) throw new InvalidOperationException("Tray icon creation failed.");
        try { using var borrowed = Icon.FromHandle(handle); return (Icon)borrowed.Clone(); }
        finally { DestroyIcon(handle); }
    }

    // The sheet enlarges the actual native pixels with nearest-neighbor, so antialiasing is reviewable.
    public static void SaveContactSheet(string path, IReadOnlyList<(string Label, TrayIconFamily Family)> families, bool dark)
    {
        const int cellWidth = 284, rowHeight = 380;
        using var sheet = new Bitmap(cellWidth * Sizes.Count, rowHeight * families.Count);
        using var g = Graphics.FromImage(sheet);
        g.Clear(dark ? Color.FromArgb(37, 37, 42) : Color.FromArgb(236, 236, 240));
        g.InterpolationMode = InterpolationMode.NearestNeighbor; g.PixelOffsetMode = PixelOffsetMode.Half;
        for (int row = 0; row < families.Count; row++) for (int i = 0; i < Sizes.Count; i++)
        {
            int x = i * cellWidth, y = row * rowHeight, size = Sizes[i];
            UiPaint.Text(g, $"{families[row].Label} / {size}px / 1x + 4x", new(x + 8, y, cellWidth - 16, 28), dark ? Color.White : Color.Black, 13);
            using var stream = new MemoryStream(families[row].Family.frames[i]); using var bitmap = new Bitmap(stream);
            g.DrawImageUnscaled(bitmap, x + (cellWidth - size) / 2, y + 32);
            g.DrawImage(bitmap, new Rectangle(x + (cellWidth - size * 4) / 2, y + 108, size * 4, size * 4), 0, 0, size, size, GraphicsUnit.Pixel);
        }
        sheet.Save(path, ImageFormat.Png);
    }

    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr CreateIconFromResourceEx(byte[] bits, uint length, [MarshalAs(UnmanagedType.Bool)] bool icon, uint version, int width, int height, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(IntPtr icon);
}
