using System.Runtime.InteropServices;
using System.Text.Json;

namespace WindowsImeCaretIndicator;

internal static class DiagnosticRunner
{
    private static readonly CaretResolver CaretResolver = new();
    private static readonly ImeStateReader ImeReader = new();

    internal static int Run()
    {
        PrintSnapshot("startup");
        using var events = new TrackingEvents(() => PrintSnapshot("event"));

        while (Native.GetMessageW(out var message, nint.Zero, 0, 0) > 0)
        {
            _ = Native.TranslateMessage(ref message);
            _ = Native.DispatchMessageW(ref message);
        }

        return 0;
    }

    private static void PrintSnapshot(string trigger)
    {
        try
        {
            if (!CaretResolver.TryGetActiveCaret(out var caret) || caret is null)
            {
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    trigger,
                    activeCaret = false,
                    at = DateTimeOffset.UtcNow
                }));
                return;
            }

            var ime = ImeReader.Read(caret);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                trigger,
                activeCaret = true,
                caret = new
                {
                    x = caret.Caret.X,
                    y = caret.Caret.Y,
                    width = caret.Caret.Width,
                    height = caret.Caret.Height,
                    focusWindow = caret.FocusWindow.ToInt64(),
                    threadId = caret.FocusThreadId,
                    source = caret.Source
                },
                ime = new
                {
                    mode = ime.Mode.ToString(),
                    languageId = $"0x{ime.LanguageId:X4}",
                    ime.Open,
                    ime.Conversion,
                    ime.Source
                },
                at = DateTimeOffset.UtcNow
            }));
        }
        catch (Exception ex)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                trigger,
                error = ex.GetType().Name,
                message = ex.Message,
                at = DateTimeOffset.UtcNow
            }));
        }
    }
}

internal static class NativeTestHost
{
    private static readonly Native.WindowProc WindowProc = WndProc;

    internal static int Run()
    {
        var module = Native.GetModuleHandleW(null);
        var windowClass = new Native.WindowClass
        {
            lpfnWndProc = WindowProc,
            hInstance = module,
            hCursor = Native.LoadCursorW(nint.Zero, (nint)32512),
            hbrBackground = (nint)6,
            lpszClassName = "WiciTestHost"
        };

        if (Native.RegisterClassW(ref windowClass) == 0 &&
            Marshal.GetLastWin32Error() != 1410)
        {
            throw new InvalidOperationException(
                $"RegisterClassW failed: {Marshal.GetLastWin32Error()}");
        }

        var window = Native.CreateWindowExW(
            0,
            "WiciTestHost",
            "Windows IME Caret Indicator Test Host",
            Native.WsOverlappedWindow | Native.WsVisible,
            Native.CwUseDefault,
            Native.CwUseDefault,
            760,
            220,
            nint.Zero,
            nint.Zero,
            module,
            nint.Zero);

        if (window == nint.Zero)
            throw new InvalidOperationException(
                $"CreateWindowExW failed: {Marshal.GetLastWin32Error()}");

        var edit = Native.CreateWindowExW(
            0x00000200,
            "EDIT",
            "Type here and move the caret",
            Native.WsChild | Native.WsVisible | Native.WsTabStop |
            Native.WsBorder | Native.EsAutoHScroll,
            25,
            55,
            690,
            34,
            window,
            (nint)1001,
            module,
            nint.Zero);

        if (edit == nint.Zero)
            throw new InvalidOperationException(
                $"CreateWindowExW(EDIT) failed: {Marshal.GetLastWin32Error()}");

        _ = Native.SetFocus(edit);

        while (Native.GetMessageW(out var message, nint.Zero, 0, 0) > 0)
        {
            _ = Native.TranslateMessage(ref message);
            _ = Native.DispatchMessageW(ref message);
        }

        return 0;
    }

    private static nint WndProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        if (message == Native.WmDestroy)
        {
            Native.PostQuitMessage(0);
            return nint.Zero;
        }

        return Native.DefWindowProcW(hwnd, message, wParam, lParam);
    }
}
