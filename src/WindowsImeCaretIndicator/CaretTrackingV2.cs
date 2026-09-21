using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace WindowsImeCaretIndicator;

internal interface ICaretProvider
{
    bool TryGetActiveCaret(out CaretState? state);
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

        var topLeft = new Native.Point(
            info.rcCaret.Left,
            info.rcCaret.Top);

        var bottomRight = new Native.Point(
            info.rcCaret.Right,
            info.rcCaret.Bottom);

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

        state = new CaretState(
            caret,
            info.hwndFocus,
            threadId,
            "Win32.GetGUIThreadInfo");

        return true;
    }
}

internal sealed class CaretResolver : IDisposable
{
    private readonly ICaretProvider[] _providers =
    {
        new Uia3Text2CaretProvider(),
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

    public void Dispose()
    {
        foreach (var provider in _providers)
        {
            if (provider is IDisposable disposable)
                disposable.Dispose();
        }
    }
}

internal sealed class ImeStateReader
{
    internal ImeReading Read(CaretState caret)
    {
        var hkl = Native.GetKeyboardLayout(caret.FocusThreadId);
        var languageId = unchecked((ushort)((long)hkl & 0xffff));

        if (languageId != ImeLogic.KoreanLanguageId)
        {
            return new ImeReading(
                ImeMode.English,
                languageId,
                null,
                null,
                "GetKeyboardLayout");
        }

        if (TryDirectImm(caret.FocusWindow, languageId, out var direct))
            return direct;

        if (TryImeWindow(caret.FocusWindow, languageId, out var compatible))
            return compatible;

        return new ImeReading(
            ImeMode.Unknown,
            languageId,
            null,
            null,
            "Unresolved");
    }

    private static bool TryDirectImm(
        nint focusWindow,
        ushort languageId,
        out ImeReading reading)
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

            if (Native.ImmGetConversionStatus(
                    himc,
                    out var conversionValue,
                    out _))
            {
                conversion = unchecked((int)conversionValue);
            }

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

    private static bool TryImeWindow(
        nint focusWindow,
        ushort languageId,
        out ImeReading reading)
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
    private readonly AutomationEventHandler _uiaSelectionHandler;
    private readonly AutomationEventHandler _uiaTextChangedHandler;
    private readonly List<nint> _winHooks = new();

    internal TrackingEvents(Action requestRefresh)
    {
        _requestRefresh = requestRefresh;
        _winEventDelegate = OnWinEvent;
        _uiaFocusHandler = OnUiaFocusChanged;
        _uiaSelectionHandler = OnUiaTextEvent;
        _uiaTextChangedHandler = OnUiaTextEvent;

        AddWinHook(
            Native.EventSystemForeground,
            Native.EventSystemForeground);

        AddWinHook(
            Native.EventObjectFocus,
            Native.EventObjectFocus);

        AddWinHook(
            Native.EventObjectLocationChange,
            Native.EventObjectLocationChange);

        Automation.AddAutomationFocusChangedEventHandler(
            _uiaFocusHandler);

        Automation.AddAutomationEventHandler(
            TextPattern.TextSelectionChangedEvent,
            AutomationElement.RootElement,
            TreeScope.Subtree,
            _uiaSelectionHandler);

        Automation.AddAutomationEventHandler(
            TextPattern.TextChangedEvent,
            AutomationElement.RootElement,
            TreeScope.Subtree,
            _uiaTextChangedHandler);
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
            Native.WineventOutOfContext |
            Native.WineventSkipOwnProcess);

        if (hook == nint.Zero)
        {
            Dispose();
            throw new InvalidOperationException(
                "SetWinEventHook failed.");
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
        if (eventType == Native.EventObjectLocationChange &&
            idObject != Native.ObjIdCaret)
        {
            return;
        }

        _requestRefresh();
    }

    private void OnUiaFocusChanged(
        object sender,
        AutomationFocusChangedEventArgs e) =>
        _requestRefresh();

    private void OnUiaTextEvent(
        object sender,
        AutomationEventArgs e) =>
        _requestRefresh();

    public void Dispose()
    {
        try
        {
            Automation.RemoveAutomationFocusChangedEventHandler(
                _uiaFocusHandler);

            Automation.RemoveAutomationEventHandler(
                TextPattern.TextSelectionChangedEvent,
                AutomationElement.RootElement,
                _uiaSelectionHandler);

            Automation.RemoveAutomationEventHandler(
                TextPattern.TextChangedEvent,
                AutomationElement.RootElement,
                _uiaTextChangedHandler);
        }
        catch (InvalidOperationException)
        {
        }

        foreach (var hook in _winHooks)
        {
            if (hook != nint.Zero)
                _ = Native.UnhookWinEvent(hook);
        }

        _winHooks.Clear();
    }
}
