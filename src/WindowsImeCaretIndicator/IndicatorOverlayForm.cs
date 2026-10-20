using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace WindowsImeCaretIndicator;

internal sealed class IndicatorOverlayForm : Form
{
    private ImeMode _mode;

    internal IndicatorOverlayForm()
    {
        AutoScaleMode = AutoScaleMode.None;
        AllowTransparency = true;
        BackColor = Color.Black;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        DoubleBuffered = true;
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= 0x00000020 | 0x00000080 | 0x00080000 | 0x08000000;
            return parameters;
        }
    }

    internal void Present(Rectangle bounds, ImeMode mode)
    {
        if (OverlayPresentation.LabelFor(mode).Length == 0)
        {
            Dismiss();
            return;
        }

        _mode = mode;
        if (Bounds != bounds)
            Bounds = bounds;
        UpdateRoundedRegion();
        if (!Visible)
            Show();
        Invalidate();
    }

    internal void Dismiss()
    {
        if (Visible)
            Hide();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        OverlayPresentation.Draw(e.Graphics, ClientRectangle, _mode);
    }

    private void UpdateRoundedRegion()
    {
        if (ClientSize.Width <= 0 || ClientSize.Height <= 0)
            return;

        using var path = OverlayPresentation.CreateTilePath(ClientRectangle);
        var previous = Region;
        Region = new Region(path);
        previous?.Dispose();
    }
}

internal static class OverlayPresentation
{
    internal static string LabelFor(ImeMode mode) => mode switch
    {
        ImeMode.Korean => "ㅎ",
        ImeMode.English => "A",
        _ => string.Empty
    };

    internal static void Draw(Graphics graphics, Rectangle bounds, ImeMode mode)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0)
            return;

        var state = graphics.Save();
        try
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            using var tile = CreateTilePath(bounds);
            graphics.FillPath(Brushes.Black, tile);
            using var glyph = CreateGlyphPath(bounds, mode);
            if (glyph.PointCount != 0)
                graphics.FillPath(Brushes.White, glyph);
        }
        finally
        {
            graphics.Restore(state);
        }
    }

    internal static GraphicsPath CreateGlyphPath(Rectangle bounds, ImeMode mode)
    {
        var path = new GraphicsPath();
        var label = LabelFor(mode);
        var side = Math.Min(bounds.Width, bounds.Height);
        var inset = Math.Max(1f, side / 9f);
        var availableWidth = bounds.Width - 2 * inset;
        var availableHeight = bounds.Height - 2 * inset;
        if (label.Length == 0 || availableWidth <= 0 || availableHeight <= 0)
            return path;

        // Fit the visible bold outline, not the font's line box. This avoids
        // wasting the small tile on font ascent/descent and keeps both glyphs
        // large without clipping Korean strokes or stretching their proportions.
        using var font = new Font("Malgun Gothic", 64f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var format = StringFormat.GenericTypographic;
        path.AddString(label, font.FontFamily, (int)font.Style, font.Size, PointF.Empty, format);
        var ink = path.GetBounds();
        if (ink.Width <= 0 || ink.Height <= 0)
            return path;

        var scale = Math.Min(availableWidth / ink.Width, availableHeight / ink.Height);
        var x = bounds.Left + (bounds.Width - ink.Width * scale) / 2f;
        var y = bounds.Top + (bounds.Height - ink.Height * scale) / 2f;
        using var transform = new Matrix(scale, 0, 0, scale, x - ink.Left * scale, y - ink.Top * scale);
        path.Transform(transform);
        return path;
    }

    internal static GraphicsPath CreateTilePath(Rectangle rect)
    {
        var path = new GraphicsPath();
        if (rect.Width <= 0 || rect.Height <= 0)
            return path;

        var radius = Math.Max(2, Math.Min(rect.Width, rect.Height) / 4);
        var diameter = Math.Min(Math.Min(rect.Width, rect.Height), radius * 2);
        path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
