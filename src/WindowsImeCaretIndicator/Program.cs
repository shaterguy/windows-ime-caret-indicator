using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace WindowsImeCaretIndicator;

internal enum CaretSource
{
    Win32,
    UiAutomation
}

internal enum ImeMode
{
    Unknown,
    English,
    Korean
}

internal sealed record CaretSnapshot(
    Rectangle Bounds,
    nint FocusWindow,
    nint CaretWindow,
    uint FocusThreadId,
    CaretSource Source,
    DateTimeOffset CapturedAt);

internal sealed record ImeSnapshot(
    ImeMode Mode,
    ushort LanguageId,
    bool? OpenStatus,
    int? ConversionMode,
    string Source,
    DateTimeOffset CapturedAt);

internal static class ImeStateNormalizer
{
    internal const int ImeCmodeNative = 0x0001;
    internal const ushort KoreanLanguageId = 0x0412;

    internal static ImeMode Normalize(ushort languageId, bool? openStatus, int? conversionMode)
    {
        if (languageId != KoreanLanguageId)
        {
            return ImeMode.English;
        }

        if (openStatus is false)
        {
            return ImeMode.English;
        }

        if (conversionMode is null)
        {
            return ImeMode.Unknown;
        }

        return (conversionMode.Value & ImeCmodeNative) != 0
            ? ImeMode.Korean
            : ImeMode.English;
    }
}

internal static class OverlayPlacement
{
    internal static Rectangle Choose(Rectangle caret, Size overlay, Rectangle workArea, int gapX, int gapY)
    {
        var candidates = new[]
        {
            new Point(caret.Right + gapX, caret.Bottom + gapY),
            new Point(caret.Left - overlay.Width - gapX, caret.Bottom + gapY),
            new Point(caret.Right + gapX, caret.Top - overlay.Height - gapY),
            new Point(caret.Left - overlay.Width - gapX, caret.Top - overlay.Height - gapY)
        };

        foreach (var point in candidates)
        {
            var candidate = new Rectangle(point, overlay);
            if (workArea.Contains(candidate))
            {
                return candidate;
            }
        }

        var x = Math.Clamp(caret.Right + gapX, workArea.Left, Math.Max(workArea.Left, workArea.Right - overlay.Width));
        var y = Math.Clamp(caret.Bottom + gapY, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - overlay.Height));
        return new Rectangle(x, y, overlay.Width, overlay.Height);
    }
}

internal sealed class Win32CaretProvider
{
    internal bool TryGetActiveCaret(out CaretSnapshot? snapshot)
    {
        snapshot = null;
        var foreground = NativeMethods.GetForegroundWindow();
        if (foreground == nint.Zero)
        {
            return false;
        }

        var threadId = NativeMethods.GetWindowThreadProcessId(foreground, out _);
        if (threadId == 0)
        {
            return false;
        }

        var info = new NativeMethods.GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf<NativeMethods.GuiThreadInfo>()
        };

        if (!NativeMethods.GetGUIThreadInfo(threadId, ref info) ||
            info.hwndFocus == nint.Zero ||
            info.hwndCaret == nint.Zero)
        {
            return false;
        }

        var topLeft = new NativeMethods.Point(info.rcCaret.Left, info.rcCaret.Top);
        var bottomRight = new NativeMethods.Point(info.rcCaret.Right, info.rcCaret.Bottom);
        if (!NativeMethods.ClientToScreen(info.hwndCaret, ref topLeft) ||
            !NativeMethods.ClientToScreen(info.hwndCaret, ref bottomRight))
        {
            return false;
        }

        snapshot = new CaretSnapshot(
            Bounds: new Rectangle(
                topLeft.X,
                topLeft.Y,
                Math.Max(1, bottomRight.X - topLeft.X),
                Math.Max(1, bottomRight.Y - topLeft.Y)),
            FocusWindow: info.hwndFocus,
            CaretWindow: info.hwndCaret,
            FocusThreadId: threadId,
            Source: CaretSource.Win32,
            CapturedAt: DateTimeOffset.UtcNow);
        return true;
    }
}

internal sealed class Imm32ImeStateProvider
{
    internal ImeSnapshot Read(CaretSnapshot caret)
    {
        var hkl = NativeMethods.GetKeyboardLayout(caret.FocusThreadId);
        var languageId = unchecked((ushort)((long)hkl & 0xffff));
        bool? openStatus = null;
        int? conversionMode = null;
        var source = "GetKeyboardLayout";

        var context = NativeMethods.ImmGetContext(caret.FocusWindow);
        if (context != nint.Zero)
        {
            try
            {
                openStatus = NativeMethods.ImmGetOpenStatus(context);
                if (NativeMethods.ImmGetConversionStatus(context, out var conversion, out _))
                {
                    conversionMode = unchecked((int)conversion);
                }

                source = "IMM32";
            }
            finally
            {
                _ = NativeMethods.ImmReleaseContext(caret.FocusWindow, context);
            }
        }

        return new ImeSnapshot(
            ImeStateNormalizer.Normalize(languageId, openStatus, conversionMode),
            languageId,
            openStatus,
            conversionMode,
            source,
            DateTimeOffset.UtcNow);
    }
}

internal sealed class DiagnosticSampler
{
    private readonly Win32CaretProvider _caretProvider = new();
    private readonly Imm32ImeStateProvider _imeProvider = new();

    internal string CaptureJson(string trigger)
    {
        if (!_caretProvider.TryGetActiveCaret(out var caret) || caret is null)
        {
            return JsonSerializer.Serialize(new
            {
                trigger,
                activeCaret = false,
                capturedAt = DateTimeOffset.UtcNow
            });
        }

        var ime = _imeProvider.Read(caret);
        return JsonSerializer.Serialize(new
        {
            trigger,
            activeCaret = true,
            caret = new
            {
                x = caret.Bounds.X,
                y = caret.Bounds.Y,
                width = caret.Bounds.Width,
                height = caret.Bounds.Height,
                focusWindow = caret.FocusWindow.ToInt64(),
                caretWindow = caret.CaretWindow.ToInt64(),
                thread = caret.FocusThreadId,
                source = caret.Source.ToString()
            },
            ime = new
            {
                mode = ime.Mode.ToString(),
                languageId = $"0x{ime.LanguageId:X4}",
                open = ime.OpenStatus,
                conversion = ime.ConversionMode,
                source = ime.Source
            },
            capturedAt = DateTimeOffset.UtcNow
        });
    }
}

internal sealed class WinEventMonitor : IDisposable
{
    private const uint EventSystemForeground = 0x0003;
    private const uint EventObjectFocus = 0x8005;
    private const uint EventObjectLocationChange = 0x800B;
    private const uint WineventOutOfContext = 0x0000;
    private const uint WineventSkipOwnProcess = 0x0002;
    private const int ObjidCaret = unchecked((int)0xFFFFFFF8);

    private readonly NativeMethods.WinEventDelegate _callback;
    private readonly nint[] _hooks;
    private readonly DiagnosticSampler _sampler = new();
    private bool _disposed;

    internal WinEventMonitor()
    {
        _callback = OnWinEvent;
        _hooks = new[]
        {
            NativeMethods.SetWinEventHook(EventSystemForeground, EventSystemForeground, nint.Zero, _callback, 0, 0, WineventOutOfContext | WineventSkipOwnProcess),
            NativeMethods.SetWinEventHook(EventObjectFocus, EventObjectFocus, nint.Zero, _callback, 0, 0, WineventOutOfContext | WineventSkipOwnProcess),
            NativeMethods.SetWinEventHook(EventObjectLocationChange, EventObjectLocationChange, nint.Zero, _callback, 0, 0, WineventOutOfContext | WineventSkipOwnProcess)
        };

        if (_hooks.Any(static hook => hook == nint.Zero))
        {
            Dispose();
            throw new InvalidOperationException("Failed to install one or more WinEvent hooks.");
        }
    }

    internal void WriteInitialSample()
    {
        Console.WriteLine(_sampler.CaptureJson("startup"));
    }

    private void OnWinEvent(nint hook, uint eventType, nint hwnd, int idObject, int idChild, uint eventThread, uint eventTime)
    {
        if (_disposed)
        {
            return;
        }

        if (eventType == EventObjectLocationChange && idObject != ObjidCaret)
        {
            return;
        }

        var trigger = eventType switch
        {
            EventSystemForeground => "foreground",
            EventObjectFocus => "focus",
            EventObjectLocationChange => "caret-location",
            _ => "event"
        };

        Console.WriteLine(_sampler.CaptureJson(trigger));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        foreach (var hook in _hooks)
        {
            if (hook != nint.Zero)
            {
                _ = NativeMethods.UnhookWinEvent(hook);
            }
        }
    }
}

internal static class SelfTests
{
    internal static int Run()
    {
        var failures = new List<string>();
        Check("non-Korean layout is English", () => Equal(ImeMode.English, ImeStateNormalizer.Normalize(0x0409, null, null)), failures);
        Check("closed Korean IME is English", () => Equal(ImeMode.English, ImeStateNormalizer.Normalize(ImeStateNormalizer.KoreanLanguageId, false, ImeStateNormalizer.ImeCmodeNative)), failures);
        Check("Korean native conversion is Korean", () => Equal(ImeMode.Korean, ImeStateNormalizer.Normalize(ImeStateNormalizer.KoreanLanguageId, true, ImeStateNormalizer.ImeCmodeNative)), failures);
        Check("Korean alphanumeric conversion is English", () => Equal(ImeMode.English, ImeStateNormalizer.Normalize(ImeStateNormalizer.KoreanLanguageId, true, 0)), failures);
        Check("unknown Korean conversion stays unknown", () => Equal(ImeMode.Unknown, ImeStateNormalizer.Normalize(ImeStateNormalizer.KoreanLanguageId, true, null)), failures);
        Check("overlay prefers lower-right", LowerRight, failures);
        Check("overlay flips left at right edge", RightEdgeFlip, failures);
        Check("overlay supports negative monitor coordinates", NegativeCoordinates, failures);

        foreach (var failure in failures)
        {
            Console.Error.WriteLine(failure);
        }

        Console.WriteLine($"{8 - failures.Count}/8 tests passed.");
        return failures.Count == 0 ? 0 : 1;
    }

    private static void LowerRight()
    {
        Equal(
            new Rectangle(105, 122, 16, 16),
            OverlayPlacement.Choose(
                new Rectangle(100, 100, 1, 20),
                new Size(16, 16),
                new Rectangle(0, 0, 1920, 1080),
                4,
                2));
    }

    private static void RightEdgeFlip()
    {
        Equal(
            new Rectangle(1895, 122, 16, 16),
            OverlayPlacement.Choose(
                new Rectangle(1915, 100, 1, 20),
                new Size(16, 16),
                new Rectangle(0, 0, 1920, 1080),
                4,
                2));
    }

    private static void NegativeCoordinates()
    {
        var workArea = new Rectangle(-1920, 0, 1920, 1080);
        var result = OverlayPlacement.Choose(
            new Rectangle(-20, 1000, 1, 20),
            new Size(16, 16),
            workArea,
            4,
            2);

        if (!workArea.Contains(result))
        {
            throw new InvalidOperationException($"Overlay escaped negative-coordinate work area: {result}");
        }
    }

    private static void Check(string name, Action action, ICollection<string> failures)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            failures.Add($"FAIL {name}: {ex.Message}");
        }
    }

    private static void Equal<T>(T expected, T actual) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"expected {expected}, actual {actual}");
        }
    }
}

internal static class NativeTestHost
{
    private const uint WsOverlappedWindow = 0x00CF0000;
    private const uint WsVisible = 0x10000000;
    private const uint WsChild = 0x40000000;
    private const uint WsTabStop = 0x00010000;
    private const uint WsBorder = 0x00800000;
    private const uint WsVScroll = 0x00200000;
    private const uint EsAutoHScroll = 0x0080;
    private const uint EsMultiLine = 0x0004;
    private const uint EsAutoVScroll = 0x0040;
    private const uint WsExClientEdge = 0x00000200;
    private const int SwShow = 5;
    private const uint WmDestroy = 0x0002;
    private const int ColorWindow = 5;
    private const int IdcArrow = 32512;
    private const int CwUseDefault = unchecked((int)0x80000000);

    private const string WindowClassName = "WiciNativeTestHostWindow";
    private static readonly NativeMethods.WindowProc WindowProc = WndProc;

    internal static int Run()
    {
        var module = NativeMethods.GetModuleHandleW(null);
        var windowClass = new NativeMethods.WindowClass
        {
            style = 0,
            lpfnWndProc = WindowProc,
            hInstance = module,
            hCursor = NativeMethods.LoadCursorW(nint.Zero, (nint)IdcArrow),
            hbrBackground = (nint)(ColorWindow + 1),
            lpszClassName = WindowClassName
        };

        var atom = NativeMethods.RegisterClassW(ref windowClass);
        if (atom == 0 && Marshal.GetLastWin32Error() != 1410)
        {
            throw new InvalidOperationException($"RegisterClassW failed: {Marshal.GetLastWin32Error()}");
        }

        var window = NativeMethods.CreateWindowExW(
            0,
            WindowClassName,
            "Windows IME Caret Indicator Test Host",
            WsOverlappedWindow | WsVisible,
            CwUseDefault,
            CwUseDefault,
            820,
            500,
            nint.Zero,
            nint.Zero,
            module,
            nint.Zero);

        if (window == nint.Zero)
        {
            throw new InvalidOperationException($"CreateWindowExW failed: {Marshal.GetLastWin32Error()}");
        }

        var single = NativeMethods.CreateWindowExW(
            WsExClientEdge,
            "EDIT",
            "Single-line Win32 edit control",
            WsChild | WsVisible | WsTabStop | WsBorder | EsAutoHScroll,
            30,
            40,
            740,
            32,
            window,
            (nint)1001,
            module,
            nint.Zero);

        _ = NativeMethods.CreateWindowExW(
            WsExClientEdge,
            "EDIT",
            "Multi-line Win32 edit control\r\nUse arrows, Home/End, Ctrl+Arrow, Enter, selection and scrolling.",
            WsChild | WsVisible | WsTabStop | WsBorder | WsVScroll | EsMultiLine | EsAutoVScroll,
            30,
            100,
            740,
            280,
            window,
            (nint)1002,
            module,
            nint.Zero);

        if (single == nint.Zero)
        {
            throw new InvalidOperationException($"CreateWindowExW(EDIT) failed: {Marshal.GetLastWin32Error()}");
        }

        _ = NativeMethods.ShowWindow(window, SwShow);
        _ = NativeMethods.UpdateWindow(window);
        _ = NativeMethods.SetFocus(single);

        while (NativeMethods.GetMessageW(out var message, nint.Zero, 0, 0) > 0)
        {
            _ = NativeMethods.TranslateMessage(ref message);
            _ = NativeMethods.DispatchMessageW(ref message);
        }

        return 0;
    }

    private static nint WndProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        if (message == WmDestroy)
        {
            NativeMethods.PostQuitMessage(0);
            return nint.Zero;
        }

        return NativeMethods.DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

internal static class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point
    {
        public int X;
        public int Y;

        public Point(int x, int y)
        {
            X = x;
            Y = y;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct GuiThreadInfo
    {
        public uint cbSize;
        public uint flags;
        public nint hwndActive;
        public nint hwndFocus;
        public nint hwndCapture;
        public nint hwndMenuOwner;
        public nint hwndMoveSize;
        public nint hwndCaret;
        public Rect rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Message
    {
        public nint hwnd;
        public uint message;
        public nuint wParam;
        public nint lParam;
        public uint time;
        public Point pt;
        public uint lPrivate;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct WindowClass
    {
        public uint style;
        public WindowProc lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public nint hInstance;
        public nint hIcon;
        public nint hCursor;
        public nint hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
    }

    internal delegate void WinEventDelegate(nint hWinEventHook, uint eventType, nint hwnd, int idObject, int idChild, uint idEventThread, uint eventTime);
    internal delegate nint WindowProc(nint hwnd, uint message, nuint wParam, nint lParam);

    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern uint GetWindowThreadProcessId(nint hWnd, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetGUIThreadInfo(uint idThread, ref GuiThreadInfo lpgui);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ClientToScreen(nint hWnd, ref Point lpPoint);

    [DllImport("user32.dll")]
    internal static extern nint GetKeyboardLayout(uint idThread);

    [DllImport("imm32.dll")]
    internal static extern nint ImmGetContext(nint hWnd);

    [DllImport("imm32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ImmReleaseContext(nint hWnd, nint hIMC);

    [DllImport("imm32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ImmGetOpenStatus(nint hIMC);

    [DllImport("imm32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ImmGetConversionStatus(nint hIMC, out uint conversion, out uint sentence);

    [DllImport("user32.dll")]
    internal static extern nint SetWinEventHook(uint eventMin, uint eventMax, nint hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnhookWinEvent(nint hWinEventHook);

    [DllImport("user32.dll")]
    internal static extern int GetMessageW(out Message lpMsg, nint hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool TranslateMessage(ref Message lpMsg);

    [DllImport("user32.dll")]
    internal static extern nint DispatchMessageW(ref Message lpMsg);

    [DllImport("user32.dll")]
    internal static extern void PostQuitMessage(int exitCode);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern ushort RegisterClassW(ref WindowClass lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern nint CreateWindowExW(
        uint dwExStyle,
        string lpClassName,
        string lpWindowName,
        uint dwStyle,
        int x,
        int y,
        int nWidth,
        int nHeight,
        nint hWndParent,
        nint hMenu,
        nint hInstance,
        nint lpParam);

    [DllImport("user32.dll")]
    internal static extern nint DefWindowProcW(nint hWnd, uint msg, nuint wParam, nint lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    internal static extern nint GetModuleHandleW(string? lpModuleName);

    [DllImport("user32.dll")]
    internal static extern nint LoadCursorW(nint hInstance, nint lpCursorName);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ShowWindow(nint hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UpdateWindow(nint hWnd);

    [DllImport("user32.dll")]
    internal static extern nint SetFocus(nint hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetProcessDpiAwarenessContext(nint value);
}

internal static class Program
{
    private static uint _diagnosticThreadId;

    private static int Main(string[] args)
    {
        _ = NativeMethods.SetProcessDpiAwarenessContext(new nint(-4));

        if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase))
        {
            return SelfTests.Run();
        }

        if (args.Contains("--test-host", StringComparer.OrdinalIgnoreCase))
        {
            return NativeTestHost.Run();
        }

        if (args.Contains("--diagnose", StringComparer.OrdinalIgnoreCase))
        {
            return RunDiagnostics();
        }

        Console.WriteLine("Windows IME Caret Indicator development foundation");
        Console.WriteLine("  --self-test  Run deterministic IME/placement tests");
        Console.WriteLine("  --test-host  Open native Win32 edit controls for caret diagnostics");
        Console.WriteLine("  --diagnose   Observe foreground/focus/caret events and IME state");
        return 0;
    }

    private static int RunDiagnostics()
    {
        _diagnosticThreadId = NativeMethods.GetCurrentThreadId();
        using var monitor = new WinEventMonitor();
        monitor.WriteInitialSample();

        Console.CancelKeyPress += OnCancelKeyPress;
        try
        {
            while (NativeMethods.GetMessageW(out var message, nint.Zero, 0, 0) > 0)
            {
                _ = NativeMethods.TranslateMessage(ref message);
                _ = NativeMethods.DispatchMessageW(ref message);
            }
        }
        finally
        {
            Console.CancelKeyPress -= OnCancelKeyPress;
        }

        return 0;
    }

    private static void OnCancelKeyPress(object? sender, ConsoleCancelEventArgs e)
    {
        e.Cancel = true;
        _ = NativeMethods.PostThreadMessageW(_diagnosticThreadId, 0x0012, nuint.Zero, nint.Zero);
    }
}
