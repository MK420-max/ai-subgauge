using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;

namespace AISubGauge.UI;

internal sealed class LogoCatalog : IDisposable
{
    private readonly Dictionary<string, Bitmap> _images = new(StringComparer.Ordinal);
    private readonly Dictionary<string, bool> _monochrome = new(StringComparer.Ordinal);

    public bool IsMonochromeDark(string resource)
    {
        if (_monochrome.TryGetValue(resource, out bool result)) return result;
        Bitmap image = Get(resource);
        long visible = 0, dark = 0;
        for (int y = 0; y < image.Height; y++)
        for (int x = 0; x < image.Width; x++)
        {
            Color pixel = image.GetPixel(x, y);
            if (pixel.A < 32) continue;
            visible++;
            int maximum = Math.Max(pixel.R, Math.Max(pixel.G, pixel.B));
            int minimum = Math.Min(pixel.R, Math.Min(pixel.G, pixel.B));
            if (maximum <= 100 && maximum - minimum <= 24) dark++;
        }
        result = visible > 0 && dark >= visible * 0.98;
        _monochrome.Add(resource, result);
        return result;
    }

    public Bitmap Get(string resource)
    {
        if (_images.TryGetValue(resource, out Bitmap? image))
            return image;
        using Stream stream = typeof(LogoCatalog).Assembly.GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException(I18n.Get("windows.an.embedded.brand.icon.is.missing"));
        using var original = new Bitmap(stream);
        var copy = new Bitmap(original); // Detach from the resource stream before it is disposed.
        _images.Add(resource, copy);
        return copy;
    }

    public void Dispose()
    {
        foreach (Bitmap image in _images.Values)
            image.Dispose();
        _images.Clear();
        _monochrome.Clear();
    }
}
