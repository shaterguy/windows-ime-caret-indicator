using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace WindowsImeCaretIndicator;

internal interface ICaretProvider
{
    bool TryGetActiveCaret(out CaretState? state);
}

internal sealed class UiaCaretProvider : ICaretProvider
{
    public bool TryGetActiveCaret(out CaretState? state)
    {
        state = null;

        AutomationElement? focused;
        try
        {
            focused = AutomationElement.FocusedElement;
        }
        catch (ElementNotAvailableException)
        {
            return false;
        }
        catch (COMException)
        {
            return false;
        }

        if (focused is null)
            return false;

        try
        {
            if (!focused.Current.HasKeyboardFocus)
                return false;

            if (!focused.TryGetCurrentPattern(TextPattern2.Pattern, out var rawPattern) ||
                rawPattern is not TextPattern2 textPattern)
            {
                return false;
            }

            var range = textPattern.GetCaretRange(out var isActive);
            if (!isActive || range is null)
                return false;

            if (!TryGetCaretRectangle(range, out var caret))
                return false;

            var hwnd = (nint)focused.Current.NativeWindowHandle;
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

            state = new CaretState(caret, hwnd, threadId, "UIA.TextPattern2");
            return true;
        }
        catch (ElementNotAvailableException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (COMException)
        {
            return false;
        }
    }

    private static bool TryGetCaretRectangle(TextPatternRange range, out Rectangle caret)
    {
        if (TryFirstRectangle(range, out var rect))
        {
            caret = ToCaretEdge(rect, useLeftEdge: true);
            return true;
        }

        var after = range.Clone();
        try
        {
            if (after.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, 1) != 0 &&
                TryFirstRectangle(after, out rect))
            {
                caret = ToCaretEdge(rect, useLeftEdge: true);
                return true;
            }
        }
        catch (InvalidOperationException)
        {
        }

        var before = range.Clone();
        try
        {
            if (before.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -1) != 0 &&
                TryLastRectangle(before, out rect))
            {
                caret = ToCaretEdge(rect, useLeftEdge: false);
                return true;
            }
        }
        catch (InvalidOperationException)
        {
        }

        caret = Rectangle.Empty;
        return false;
    }

    private static bool TryFirstRectangle(TextPatternRange range, out RectangleF rect)
    {
        var raw = range.GetBoundingRectangles();
        if (raw is not { Length: >= 4 })
        {
            rect = RectangleF.Empty;
            return false;
        }

        rect = new RectangleF((float)raw[0], (float)raw[1], (float)raw[2], (float)raw[3]);
        return IsUsable(rect);
    }

    private static bool TryLastRectangle(TextPatternRange range, out RectangleF rect)
    {
        var raw = range.GetBoundingRectangles();
        if (raw is not { Length: >= 4 })
        {
            rect = RectangleF.Empty;
            return false;
        }

        var i = raw.Length - 4;
        rect = new RectangleF((float)raw[i], (float)raw[i + 1], (float)raw[i + 2], (float)raw[i + 3]);
        return IsUsable(rect);
    }

    private static bool IsUsable(RectangleF rect) =>
        float.IsFinite(rect.X) &&
        float.IsFinite(rect.Y) &&
        float.IsFinite(rect.Width) &&
        float.IsFinite(rect.Height) &&
        rect.Height > 0.5f;

    private static Rectangle ToCaretEdge(RectangleF rect, bool useLeftEdge)
    {
        var x = (int)Math.Round(useLeftEdge ? rect.Left : rect.Right);
        var y = (int)Math.Round(rect.Top);
        var height = Math.Max(1, (int)Math.Round(rect.Height));
        return new Rectangle(x, y, 1, height);
    }

    private static bool TryGetForegroundFocus(out nint hwnd, out uint threadId)
    {
        hwnd = nint.Zero;
        threadId = 0;

        var foreground = Native.GetForegroundWindow();
        if (foreground == nint.Zero)
            return false;

        threadId = Native.GetWindowThreadProcessId(foreground, out _);
        return threadId != 0 && TryGetThreadFocus(threadId, out hwnd);
    }

    private static bool TryGetThreadFocus(uint threadId, out nint hwnd)
    {
        var info = new Native.GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf<Native.GuiThreadInfo>()
        };

        if (!Native.GetGUIThreadInfo(threadId, ref info) || info.hwndFocus == nint.Zero)
        {
            hwnd = nint.Zero;
            return false;
        }

        hwnd = info.hwndFocus;
        return true;
    }
}

internal sealed class Win32CaretProvider : ICaretProvider
{
    public bool TryGetActiveCaret(out CaretState? state)
    {
        state = null;

        var foreground = Native.GetForegroundWindow();
        if (foreground == nint.Zero)
            return false;

        var threadId = Native.GetWindowThreadProcessId(foreground, out _);
        if (threadId == 0)
            return false;

        var info = new Native.GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf<Native.GuiThreadInfo>()
        };

        if (!Native.GetGUIThreadInfo(threadId, ref info) ||
            info.hwndFocus == nint.Zero ||
            info.hwndCaret == nint.Zero)
        {
            return false;
        }

        var topLeft = new Native.Point(info.rcCaret.Left, info.rcCaret.Top);
        var bottomRight = new Native.Point(info.rcCaret.Right, info.rcCaret.Bottom);

        if (!Native.ClientToScreen(info.hwndCaret, ref topLeft) ||
            !Native.ClientToScreen(info.hwndCaret, ref bottomRight))
        {
            return false;
        }

        var caret = new Rectangle(
            topLeft.X,
            topLeft.Y,
            Math.Max(1, bottomRight.X - topLeft.X),
            Math.Max(1, bottomRight.Y - topLeft.Y));

        if (caret.Height <= 0)
            return false;

        state = new CaretState(caret, info.hwndFocus, threadId, "Win32.GetGUIThreadInfo");
        return true;
    }
}

internal sealed class CaretResolver
{
    private readonly ICaretProvider[] _providers =
    {
        new UiaCaretProvider(),
        new Win32CaretProvider()
    };

    internal bool TryGetActiveCaret(out CaretState? state)
    {
        foreach (var provider in _providers)
        {
            if (provider.TryGetActiveCaret(out state) && state is not null)
                return true;
        }

        state = null;
        return false;
    }
}

internal sealed class ImeStateReader
{
    internal ImeReading Read(CaretState caret)
    {
        var hkl = Native.GetKeyboardLayout(caret.FocusThreadId);
        var languageId = unchecked((ushort)((long)hkl & 0xffff));

        if (languageId != ImeLogic.KoreanLanguageId)
            return new ImeReading(ImeMode.English, languageId, null, null, "GetKeyboardLayout");

        if (TryDirectImm(caret.FocusWindow, languageId, out var direct))
            return direct;

        if (TryImeWindow(caret.FocusWindow, languageId, out var compatible))
            return compatible;

        return new ImeReading(ImeMode.Unknown, languageId, null, null, "Unresolved");
    }

    private static bool TryDirectImm(nint focusWindow, ushort languageId, out ImeReading reading)
    {
        var himc = Native.ImmGetContext(focusWindow);
        if (himc == nint.Zero)
        {
            reading = default!;
            return false;
        }

        try
        {
            var open = Native.ImmGetOpenStatus(himc);
            int? conversion = null;
            if (Native.ImmGetConversionStatus(himc, out var conversionValue, out _))
                conversion = unchecked((int)conversionValue);

            reading = new ImeReading(
                ImeLogic.Normalize(languageId, open, conversion),
                languageId,
                open,
                conversion,
                "IMM32.Direct");
            return conversion is not null;
        }
        finally
        {
            _ = Native.ImmReleaseContext(focusWindow, himc);
        }
    }

    private static bool TryImeWindow(nint focusWindow, ushort languageId, out ImeReading reading)
    {
        var imeWindow = Native.ImmGetDefaultIMEWnd(focusWindow);
        if (imeWindow == nint.Zero)
        {
            reading = default!;
            return false;
        }

        if (Native.SendMessageTimeoutW(
                imeWindow,
                Native.WmImeControl,
                Native.ImcGetOpenStatus,
                nint.Zero,
                Native.SmtoAbortIfHung,
                30,
                out var openResult) == nint.Zero)
        {
            reading = default!;
            return false;
        }

        var open = openResult != nint.Zero;
        int? conversion = null;

        if (Native.SendMessageTimeoutW(
                imeWindow,
                Native.WmImeControl,
                Native.ImcGetConversionMode,
                nint.Zero,
                Native.SmtoAbortIfHung,
                30,
                out var conversionResult) != nint.Zero)
        {
            conversion = unchecked((int)conversionResult);
        }

        reading = new ImeReading(
            ImeLogic.Normalize(languageId, open, conversion),
            languageId,
            open,
            conversion,
            "IMM32.DefaultImeWindow");

        return conversion is not null;
    }
}

internal sealed class TrackingEvents : IDisposable
{
    private readonly Action _requestRefresh;
    private readonly Native.WinEventDelegate _winEventDelegate;
    private readonly AutomationFocusChangedEventHandler _uiaFocusHandler;
    private readonly Native.LowLevelKeyboardProc _keyboardDelegate;
    private readonly List<nint> _winHooks = new();
    private nint _keyboardHook;

    internal TrackingEvents(Action requestRefresh)
    {
        _requestRefresh = requestRefresh;
        _winEventDelegate = OnWinEvent;
        _uiaFocusHandler = OnUiaFocusChanged;
        _keyboardDelegate = OnKeyboard;

        AddWinHook(Native.EventSystemForeground, Native.EventSystemForeground);
        AddWinHook(Native.EventObjectFocus, Native.EventObjectFocus);
        AddWinHook(Native.EventObjectLocationChange, Native.EventObjectLocationChange);

        Automation.AddAutomationFocusChangedEventHandler(_uiaFocusHandler);

        var module = Native.GetModuleHandleW(null);
        _keyboardHook = Native.SetWindowsHookExW(Native.WhKeyboardLl, _keyboardDelegate, module, 0);
        if (_keyboardHook == nint.Zero)
        {
            Dispose();
            throw new InvalidOperationException($"SetWindowsHookEx failed: {Marshal.GetLastWin32Error()}");
        }
    }

    private void AddWinHook(uint min, uint max)
    {
        var hook = Native.SetWinEventHook(
            min,
            max,
            nint.Zero,
            _winEventDelegate,
            0,
            0,
            Native.WineventOutOfContext | Native.WineventSkipOwnProcess);

        if (hook == nint.Zero)
        {
            Dispose();
            throw new InvalidOperationException("SetWinEventHook failed.");
        }

        _winHooks.Add(hook);
    }

    private void OnWinEvent(
        nint hook,
        uint eventType,
        nint hwnd,
        int idObject,
        int idChild,
        uint eventThread,
        uint eventTime)
    {
        if (eventType == Native.EventObjectLocationChange && idObject != Native.ObjIdCaret)
            return;

        _requestRefresh();
    }

    private void OnUiaFocusChanged(object sender, AutomationFocusChangedEventArgs e) =>
        _requestRefresh();

    private nint OnKeyboard(int code, nuint wParam, nint lParam)
    {
        if (code >= 0 && (wParam == Native.WmKeyDown || wParam == Native.WmSysKeyDown))
            _requestRefresh();

        return Native.CallNextHookEx(_keyboardHook, code, wParam, lParam);
    }

    public void Dispose()
    {
        try
        {
            Automation.RemoveAutomationFocusChangedEventHandler(_uiaFocusHandler);
        }
        catch (InvalidOperationException)
        {
        }

        if (_keyboardHook != nint.Zero)
        {
            _ = Native.UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = nint.Zero;
        }

        foreach (var hook in _winHooks)
            if (hook != nint.Zero)
                _ = Native.UnhookWinEvent(hook);

        _winHooks.Clear();
    }
}
