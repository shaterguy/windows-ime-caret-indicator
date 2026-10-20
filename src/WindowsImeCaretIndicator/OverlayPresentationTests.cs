using System.Drawing.Imaging;

namespace WindowsImeCaretIndicator;

internal static class OverlayPresentationTests
{
    internal static int Run(ICollection<string> errors)
    {
        var count = 0;
        void Check(string name, Action action)
        {
            count++;
            try { action(); }
            catch (Exception ex) { errors.Add($"FAIL: {name}: {ex}"); }
        }

        Check("Korean overlay is the single consonant ㅎ", () =>
            Require(OverlayPresentation.LabelFor(ImeMode.Korean) == "ㅎ"));
        Check("English overlay is uppercase A", () =>
            Require(OverlayPresentation.LabelFor(ImeMode.English) == "A"));
        Check("unknown overlay has no language label", () => RequireNoGlyph(ImeMode.Unknown));
        Check("invalid overlay mode has no language label", () => RequireNoGlyph((ImeMode)int.MaxValue));

        foreach (var dpi in new uint[] { 96, 120, 144, 192 })
        {
            Check($"bold overlay glyphs fit at {dpi} DPI", () =>
            {
                // Exercise both ends of the allowed size range, not only the
                // normal caret size. These bitmaps use the live paint routine.
                foreach (var caretHeight in new[] { 1, 1000 })
                {
                    var size = OverlayMetrics.CalculateSize(new Rectangle(0, 0, 1, caretHeight), dpi);
                    foreach (var mode in new[] { ImeMode.Korean, ImeMode.English })
                        RequireReadableGlyph(size, mode);
                }
            });
        }

        return count;
    }

    // Explicit opt-in helper for Windows verification. Each PNG contains the
    // minimum-size Korean and English tiles at their actual pixel dimensions.
    internal static IReadOnlyList<string> WriteSnapshots(string directory)
    {
        Directory.CreateDirectory(directory);
        var paths = new List<string>();
        foreach (var dpi in new uint[] { 96, 120, 144, 192 })
        {
            var size = OverlayMetrics.CalculateSize(new Rectangle(0, 0, 1, 1), dpi);
            var gap = (int)Math.Round(4 * dpi / 96.0);
            using var bitmap = new Bitmap(size.Width * 2 + gap, size.Height, PixelFormat.Format32bppArgb);
            bitmap.SetResolution(dpi, dpi);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.Clear(Color.Transparent);
                OverlayPresentation.Draw(graphics, new Rectangle(Point.Empty, size), ImeMode.Korean);
                OverlayPresentation.Draw(
                    graphics,
                    new Rectangle(new Point(size.Width + gap, 0), size),
                    ImeMode.English);
            }

            var path = Path.Combine(directory, $"overlay-glyphs-{dpi}dpi.png");
            bitmap.Save(path, ImageFormat.Png);
            paths.Add(path);
        }

        return paths;
    }

    private static void RequireNoGlyph(ImeMode mode)
    {
        Require(OverlayPresentation.LabelFor(mode).Length == 0);
        using var path = OverlayPresentation.CreateGlyphPath(new Rectangle(0, 0, 18, 18), mode);
        Require(path.PointCount == 0);
    }

    private static void RequireReadableGlyph(Size size, ImeMode mode)
    {
        var bounds = new Rectangle(Point.Empty, size);
        using var path = OverlayPresentation.CreateGlyphPath(bounds, mode);
        Require(path.PointCount > 0);
        var ink = path.GetBounds();
        var inset = Math.Max(1f, Math.Min(size.Width, size.Height) / 9f);
        const float tolerance = 0.01f;
        Require(ink.Left >= inset - tolerance && ink.Top >= inset - tolerance);
        Require(ink.Right <= size.Width - inset + tolerance && ink.Bottom <= size.Height - inset + tolerance);
        Require(Math.Max(ink.Width, ink.Height) >= Math.Min(size.Width, size.Height) * 0.75f);
        Require(Math.Min(ink.Width, ink.Height) >= Math.Min(size.Width, size.Height) * 0.5f);

        using var bitmap = new Bitmap(size.Width, size.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            OverlayPresentation.Draw(graphics, bounds, mode);
        }

        var brightPixels = 0;
        var darkPixels = 0;
        for (var y = 0; y < bitmap.Height; y++)
        {
            for (var x = 0; x < bitmap.Width; x++)
            {
                var pixel = bitmap.GetPixel(x, y);
                Require(pixel.R == pixel.G && pixel.G == pixel.B);
                if (pixel.A == 255 && pixel.R >= 240)
                {
                    brightPixels++;
                    Require(x > 0 && x < bitmap.Width - 1 && y > 0 && y < bitmap.Height - 1);
                }
                if (pixel.A == 255 && pixel.R == 0)
                    darkPixels++;
            }
        }
        Require(brightPixels >= size.Width * size.Height / 20);
        Require(darkPixels > brightPixels);
    }

    private static void Require(bool condition)
    {
        if (!condition)
            throw new InvalidOperationException("Overlay presentation assertion failed.");
    }
}
