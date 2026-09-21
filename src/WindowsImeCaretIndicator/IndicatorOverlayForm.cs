using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace WindowsImeCaretIndicator;

internal sealed class IndicatorOverlayForm : Form
{
    private string _label = string.Empty;

    internal IndicatorOverlayForm()
    {
        AutoScaleMode = AutoScaleMode.None;
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
        _label = mode == global::WindowsImeCaretIndicator.ImeMode.Korean ? "한" : "영";
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
        e.Graphics.Clear(Color.Black);
        var fontSize = Math.Max(8f, ClientSize.Height * 0.58f);
        using var font = new Font("Malgun Gothic", fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
        TextRenderer.DrawText(
            e.Graphics,
            _label,
            font,
            ClientRectangle,
            Color.White,
            Color.Black,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
            TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
    }

    private void UpdateRoundedRegion()
    {
        if (ClientSize.Width <= 0 || ClientSize.Height <= 0)
            return;

        var radius = Math.Max(2, Math.Min(ClientSize.Width, ClientSize.Height) / 4);
        var diameter = radius * 2;
        var rect = new Rectangle(0, 0, ClientSize.Width, ClientSize.Height);

        using var path = new GraphicsPath();
        path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();

        Region?.Dispose();
        Region = new Region(path);
    }
}
