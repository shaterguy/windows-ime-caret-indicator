using System.Drawing;
using System.Runtime.InteropServices;
using FlaUI.Core.Definitions;
using FlaUI.Core.Patterns;
using FlaUI.UIA3;

namespace WindowsImeCaretIndicator;

internal sealed class Uia3Text2CaretProvider : ICaretProvider, IDisposable
{
    private readonly UIA3Automation _automation = new();

    internal Uia3Text2CaretProvider()
    {
        _automation.ConnectionTimeout = TimeSpan.FromMilliseconds(500);
        _automation.TransactionTimeout = TimeSpan.FromMilliseconds(750);
    }

    public bool TryGetActiveCaret(out CaretState? state)
    {
        state = null;

        try
        {
            var focused = _automation.FocusedElement();
            if (focused is null ||
                focused.Properties.HasKeyboardFocus.ValueOrDefault != true)
            {
                return false;
            }

            if (!focused.Patterns.Text2.TryGetPattern(out var text2) ||
                text2 is null)
            {
                return false;
            }

            var range = text2.GetCaretRange(out var isActive);
            if (!isActive || range is null)
                return false;

            if (!TryGetCaretRectangle(range, out var caret))
                return false;

            var hwnd = focused.Properties.NativeWindowHandle.ValueOrDefault;
            uint threadId = 0;

            if (hwnd != nint.Zero)
                threadId = Native.GetWindowThreadProcessId(hwnd, out _);

            if (threadId == 0 || hwnd == nint.Zero)
            {
                if (!TryGetForegroundFocus(out hwnd, out threadId))
                    return false;
            }
            else if (TryGetThreadFocus(threadId, out var focusHwnd))
            {
                hwnd = focusHwnd;
            }

            state = new CaretState(
                caret,
                hwnd,
                threadId,
                "UIA3.TextPattern2.GetCaretRange");

            return true;
        }
        catch (COMException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (NotSupportedException)
        {
            return false;
        }
    }

    private static bool TryGetCaretRectangle(
        ITextRange range,
        out Rectangle caret)
    {
        if (TryFirstRectangle(range, out var rect))
        {
            caret = ToCaretEdge(rect, useLeftEdge: true);
            return true;
        }

        var after = range.Clone();
        try
        {
            if (after.MoveEndpointByUnit(
                    TextPatternRangeEndpoint.End,
                    TextUnit.Character,
                    1) != 0 &&
                TryFirstRectangle(after, out rect))
            {
                caret = ToCaretEdge(rect, useLeftEdge: true);
                return true;
            }
        }
        catch (COMException)
        {
        }
        catch (InvalidOperationException)
        {
        }

        var before = range.Clone();
        try
        {
            if (before.MoveEndpointByUnit(
                    TextPatternRangeEndpoint.Start,
                    TextUnit.Character,
                    -1) != 0 &&
                TryLastRectangle(before, out rect))
            {
                caret = ToCaretEdge(rect, useLeftEdge: false);
                return true;
            }
        }
        catch (COMException)
        {
        }
        catch (InvalidOperationException)
        {
        }

        caret = Rectangle.Empty;
        return false;
    }

    private static bool TryFirstRectangle(
        ITextRange range,
        out Rectangle rect)
    {
        var rectangles = range.GetBoundingRectangles();
        if (rectangles is not { Length: > 0 })
        {
            rect = Rectangle.Empty;
            return false;
        }

        rect = rectangles[0];
        return IsUsable(rect);
    }

    private static bool TryLastRectangle(
        ITextRange range,
        out Rectangle rect)
    {
        var rectangles = range.GetBoundingRectangles();
        if (rectangles is not { Length: > 0 })
        {
            rect = Rectangle.Empty;
            return false;
        }

        rect = rectangles[^1];
        return IsUsable(rect);
    }

    private static bool IsUsable(Rectangle rect) =>
        !rect.IsEmpty &&
        rect.Height > 0;

    private static Rectangle ToCaretEdge(
        Rectangle rect,
        bool useLeftEdge)
    {
        var x = useLeftEdge ? rect.Left : rect.Right;
        return new Rectangle(
            x,
            rect.Top,
            1,
            Math.Max(1, rect.Height));
    }

    private static bool TryGetForegroundFocus(
        out nint hwnd,
        out uint threadId)
    {
        hwnd = nint.Zero;
        threadId = 0;

        var foreground = Native.GetForegroundWindow();
        if (foreground == nint.Zero)
            return false;

        threadId = Native.GetWindowThreadProcessId(foreground, out _);
        return threadId != 0 &&
               TryGetThreadFocus(threadId, out hwnd);
    }

    private static bool TryGetThreadFocus(
        uint threadId,
        out nint hwnd)
    {
        var info = new Native.GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf<Native.GuiThreadInfo>()
        };

        if (!Native.GetGUIThreadInfo(threadId, ref info) ||
            info.hwndFocus == nint.Zero)
        {
            hwnd = nint.Zero;
            return false;
        }

        hwnd = info.hwndFocus;
        return true;
    }

    public void Dispose() => _automation.Dispose();
}
