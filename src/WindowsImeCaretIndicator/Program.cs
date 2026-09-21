using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace WindowsImeCaretIndicator;

internal enum ImeMode { Unknown, English, Korean }

internal static class ImeLogic
{
    internal const ushort KoreanLanguageId = 0x0412;
    internal const int NativeMode = 0x0001;

    internal static ImeMode Normalize(ushort languageId, bool? open, int? conversion)
    {
        if (languageId != KoreanLanguageId || open is false) return ImeMode.English;
        if (conversion is null) return ImeMode.Unknown;
        return (conversion.Value & NativeMode) != 0 ? ImeMode.Korean : ImeMode.English;
    }
}

internal static class OverlayPlacement
{
    internal static Rectangle Choose(Rectangle caret, Size overlay, Rectangle workArea, int gapX, int gapY)
    {
        var points = new[]
        {
            new Point(caret.Right + gapX, caret.Bottom + gapY),
            new Point(caret.Left - overlay.Width - gapX, caret.Bottom + gapY),
            new Point(caret.Right + gapX, caret.Top - overlay.Height - gapY),
            new Point(caret.Left - overlay.Width - gapX, caret.Top - overlay.Height - gapY)
        };

        foreach (var point in points)
        {
            var candidate = new Rectangle(point, overlay);
            if (workArea.Contains(candidate)) return candidate;
        }

        return new Rectangle(
            Math.Clamp(caret.Right + gapX, workArea.Left, Math.Max(workArea.Left, workArea.Right - overlay.Width)),
            Math.Clamp(caret.Bottom + gapY, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - overlay.Height)),
            overlay.Width,
            overlay.Height);
    }
}

internal sealed record Snapshot(
    Rectangle Caret,
    nint FocusWindow,
    uint FocusThreadId,
    ImeMode Ime,
    ushort LanguageId,
    bool? ImeOpen,
    int? Conversion,
    string ImeSource);

internal sealed class Sampler
{
    internal bool TryCapture(out Snapshot? snapshot)
    {
        snapshot = null;
        var foreground = Native.GetForegroundWindow();
        if (foreground == nint.Zero) return false;

        var threadId = Native.GetWindowThreadProcessId(foreground, out _);
        if (threadId == 0) return false;

        var info = new Native.GuiThreadInfo { cbSize = (uint)Marshal.SizeOf<Native.GuiThreadInfo>() };
        if (!Native.GetGUIThreadInfo(threadId, ref info) || info.hwndFocus == nint.Zero || info.hwndCaret == nint.Zero)
            return false;

        var a = new Native.Point(info.rcCaret.Left, info.rcCaret.Top);
        var b = new Native.Point(info.rcCaret.Right, info.rcCaret.Bottom);
        if (!Native.ClientToScreen(info.hwndCaret, ref a) || !Native.ClientToScreen(info.hwndCaret, ref b))
            return false;

        var hkl = Native.GetKeyboardLayout(threadId);
        var languageId = unchecked((ushort)((long)hkl & 0xffff));
        bool? open = null;
        int? conversion = null;
        var imeSource = "GetKeyboardLayout";

        var himc = Native.ImmGetContext(info.hwndFocus);
        if (himc != nint.Zero)
        {
            try
            {
                open = Native.ImmGetOpenStatus(himc);
                if (Native.ImmGetConversionStatus(himc, out var nativeConversion, out _))
                    conversion = unchecked((int)nativeConversion);
                imeSource = "IMM32";
            }
            finally
            {
                _ = Native.ImmReleaseContext(info.hwndFocus, himc);
            }
        }

        snapshot = new Snapshot(
            new Rectangle(a.X, a.Y, Math.Max(1, b.X - a.X), Math.Max(1, b.Y - a.Y)),
            info.hwndFocus,
            threadId,
            ImeLogic.Normalize(languageId, open, conversion),
            languageId,
            open,
            conversion,
            imeSource);
        return true;
    }

    internal string ToJson(string trigger) =>
        TryCapture(out var snapshot)
            ? JsonSerializer.Serialize(new { trigger, activeCaret = true, snapshot, at = DateTimeOffset.UtcNow })
            : JsonSerializer.Serialize(new { trigger, activeCaret = false, at = DateTimeOffset.UtcNow });
}

internal sealed class WinEventMonitor : IDisposable
{
    private const uint Foreground = 0x0003;
    private const uint Focus = 0x8005;
    private const uint Location = 0x800B;
    private const uint SkipOwnProcess = 0x0002;
    private const int ObjIdCaret = unchecked((int)0xFFFFFFF8);

    private readonly Native.WinEventDelegate _callback;
    private readonly nint[] _hooks;
    private readonly Sampler _sampler = new();

    internal WinEventMonitor()
    {
        _callback = OnEvent;
        _hooks = new[]
        {
            Native.SetWinEventHook(Foreground, Foreground, nint.Zero, _callback, 0, 0, SkipOwnProcess),
            Native.SetWinEventHook(Focus, Focus, nint.Zero, _callback, 0, 0, SkipOwnProcess),
            Native.SetWinEventHook(Location, Location, nint.Zero, _callback, 0, 0, SkipOwnProcess)
        };
        if (_hooks.Any(h => h == nint.Zero))
        {
            Dispose();
            throw new InvalidOperationException("SetWinEventHook failed.");
        }
    }

    internal void Initial() => Console.WriteLine(_sampler.ToJson("startup"));

    private void OnEvent(nint hook, uint eventType, nint hwnd, int idObject, int idChild, uint eventThread, uint eventTime)
    {
        if (eventType == Location && idObject != ObjIdCaret) return;
        var trigger = eventType == Foreground ? "foreground" : eventType == Focus ? "focus" : "caret-location";
        Console.WriteLine(_sampler.ToJson(trigger));
    }

    public void Dispose()
    {
        foreach (var hook in _hooks ?? Array.Empty<nint>())
            if (hook != nint.Zero) _ = Native.UnhookWinEvent(hook);
    }
}

internal static class Tests
{
    internal static int Run()
    {
        var errors = new List<string>();
        Check("non-Korean -> English", () => Equal(ImeMode.English, ImeLogic.Normalize(0x0409, null, null)), errors);
        Check("closed Korean -> English", () => Equal(ImeMode.English, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, false, ImeLogic.NativeMode)), errors);
        Check("native Korean -> Korean", () => Equal(ImeMode.Korean, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, true, ImeLogic.NativeMode)), errors);
        Check("alpha Korean -> English", () => Equal(ImeMode.English, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, true, 0)), errors);
        Check("unknown conversion -> Unknown", () => Equal(ImeMode.Unknown, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, true, null)), errors);
        Check("lower-right placement", () => Equal(new Rectangle(105, 122, 16, 16),
            OverlayPlacement.Choose(new Rectangle(100, 100, 1, 20), new Size(16, 16), new Rectangle(0, 0, 1920, 1080), 4, 2)), errors);
        Check("right-edge flip", () => Equal(new Rectangle(1895, 122, 16, 16),
            OverlayPlacement.Choose(new Rectangle(1915, 100, 1, 20), new Size(16, 16), new Rectangle(0, 0, 1920, 1080), 4, 2)), errors);
        Check("negative monitor", () =>
        {
            var workArea = new Rectangle(-1920, 0, 1920, 1080);
            var result = OverlayPlacement.Choose(new Rectangle(-20, 1000, 1, 20), new Size(16, 16), workArea, 4, 2);
            if (!workArea.Contains(result)) throw new InvalidOperationException(result.ToString());
        }, errors);

        foreach (var error in errors) Console.Error.WriteLine(error);
        Console.WriteLine($"{8 - errors.Count}/8 tests passed.");
        return errors.Count == 0 ? 0 : 1;
    }

    private static void Check(string name, Action action, ICollection<string> errors)
    {
        try { action(); }
        catch (Exception ex) { errors.Add($"FAIL {name}: {ex.Message}"); }
    }

    private static void Equal<T>(T expected, T actual) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"expected {expected}, actual {actual}");
    }
}

internal static class NativeTestHost
{
    private const uint WsOverlappedWindow = 0x00CF0000;
    private const uint WsVisible = 0x10000000;
    private const uint WsChild = 0x40000000;
    private const uint WsTabStop = 0x00010000;
    private const uint WsBorder = 0x00800000;
    private const uint EsAutoHScroll = 0x0080;
    private const int CwUseDefault = unchecked((int)0x80000000);
    private const uint WmDestroy = 0x0002;
    private static readonly Native.WindowProc WindowProc = WndProc;

    internal static int Run()
    {
        var module = Native.GetModuleHandleW(null);
        var wc = new Native.WindowClass
        {
            lpfnWndProc = WindowProc,
            hInstance = module,
            hCursor = Native.LoadCursorW(nint.Zero, (nint)32512),
            hbrBackground = (nint)6,
            lpszClassName = "WiciTestHost"
        };

        if (Native.RegisterClassW(ref wc) == 0 && Marshal.GetLastWin32Error() != 1410)
            throw new InvalidOperationException($"RegisterClassW failed: {Marshal.GetLastWin32Error()}");

        var window = Native.CreateWindowExW(0, "WiciTestHost", "Windows IME Caret Indicator Test Host",
            WsOverlappedWindow | WsVisible, CwUseDefault, CwUseDefault, 760, 220,
            nint.Zero, nint.Zero, module, nint.Zero);
        if (window == nint.Zero)
            throw new InvalidOperationException($"CreateWindowExW failed: {Marshal.GetLastWin32Error()}");

        var edit = Native.CreateWindowExW(0x00000200, "EDIT", "Type here and move the caret",
            WsChild | WsVisible | WsTabStop | WsBorder | EsAutoHScroll, 25, 55, 690, 34,
            window, (nint)1001, module, nint.Zero);
        if (edit == nint.Zero)
            throw new InvalidOperationException($"CreateWindowExW(EDIT) failed: {Marshal.GetLastWin32Error()}");

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
        if (message == WmDestroy)
        {
            Native.PostQuitMessage(0);
            return nint.Zero;
        }
        return Native.DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

internal static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point { public int X; public int Y; public Point(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct GuiThreadInfo
    {
        public uint cbSize; public uint flags; public nint hwndActive; public nint hwndFocus;
        public nint hwndCapture; public nint hwndMenuOwner; public nint hwndMoveSize; public nint hwndCaret; public Rect rcCaret;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Message
    {
        public nint hwnd; public uint message; public nuint wParam; public nint lParam; public uint time; public Point pt; public uint lPrivate;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct WindowClass
    {
        public uint style; public WindowProc lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public nint hInstance; public nint hIcon; public nint hCursor; public nint hbrBackground;
        public string? lpszMenuName; public string lpszClassName;
    }

    internal delegate void WinEventDelegate(nint hook, uint eventType, nint hwnd, int idObject, int idChild, uint eventThread, uint eventTime);
    internal delegate nint WindowProc(nint hwnd, uint message, nuint wParam, nint lParam);

    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint hWnd, out uint processId);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetGUIThreadInfo(uint idThread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ClientToScreen(nint hWnd, ref Point point);
    [DllImport("user32.dll")] internal static extern nint GetKeyboardLayout(uint idThread);
    [DllImport("imm32.dll")] internal static extern nint ImmGetContext(nint hWnd);
    [DllImport("imm32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ImmReleaseContext(nint hWnd, nint hImc);
    [DllImport("imm32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ImmGetOpenStatus(nint hImc);
    [DllImport("imm32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ImmGetConversionStatus(nint hImc, out uint conversion, out uint sentence);
    [DllImport("user32.dll")] internal static extern nint SetWinEventHook(uint min, uint max, nint module, WinEventDelegate callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] internal static extern int GetMessageW(out Message message, nint hWnd, uint min, uint max);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll")] internal static extern nint DispatchMessageW(ref Message message);
    [DllImport("user32.dll")] internal static extern void PostQuitMessage(int exitCode);
    [DllImport("user32.dll", SetLastError = true)] internal static extern ushort RegisterClassW(ref WindowClass windowClass);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern nint CreateWindowExW(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint param);
    [DllImport("user32.dll")] internal static extern nint DefWindowProcW(nint hWnd, uint message, nuint wParam, nint lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandleW(string? moduleName);
    [DllImport("user32.dll")] internal static extern nint LoadCursorW(nint instance, nint cursorName);
    [DllImport("user32.dll")] internal static extern nint SetFocus(nint hWnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetProcessDpiAwarenessContext(nint context);
}

internal static class Program
{
    private static int Main(string[] args)
    {
        _ = Native.SetProcessDpiAwarenessContext(new nint(-4));

        if (args.Contains("--self-test", StringComparer.OrdinalIgnoreCase)) return Tests.Run();
        if (args.Contains("--test-host", StringComparer.OrdinalIgnoreCase)) return NativeTestHost.Run();
        if (args.Contains("--diagnose", StringComparer.OrdinalIgnoreCase)) return Diagnose();

        Console.WriteLine("Windows IME Caret Indicator diagnostic foundation");
        Console.WriteLine("dotnet Program.cs -- --self-test | --test-host | --diagnose");
        return 0;
    }

    private static int Diagnose()
    {
        using var monitor = new WinEventMonitor();
        monitor.Initial();
        while (Native.GetMessageW(out var message, nint.Zero, 0, 0) > 0)
        {
            _ = Native.TranslateMessage(ref message);
            _ = Native.DispatchMessageW(ref message);
        }
        return 0;
    }
}
