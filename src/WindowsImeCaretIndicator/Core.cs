using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Forms;

namespace WindowsImeCaretIndicator;

internal enum CaretSource
{
    Win32,
    UiAutomation
}

public enum ImeMode
{
    Unknown,
    English,
    Korean
}

internal sealed record CaretSnapshot(
    bool IsActive,
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

internal interface ICaretProvider
{
    bool TryGetActiveCaret(out CaretSnapshot? snapshot);
}

internal interface IImeStateProvider
{
    ImeSnapshot Read(CaretSnapshot caret);
}

public static class ImeStateNormalizer
{
    public const int ImeCmodeNative = 0x0001;
    public const ushort KoreanLanguageId = 0x0412;

    public static ImeMode Normalize(ushort languageId, bool? openStatus, int? conversionMode)
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

public static class OverlayPlacement
{
    public static Rectangle Choose(Rectangle caret, Size overlay, Rectangle workArea, int gapX, int gapY)
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

internal sealed class Win32CaretProvider : ICaretProvider
{
    public bool TryGetActiveCaret(out CaretSnapshot? snapshot)
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

        if (!NativeMethods.GetGUIThreadInfo(threadId, ref info) || info.hwndFocus == nint.Zero || info.hwndCaret == nint.Zero)
        {
            return false;
        }

        var topLeft = new NativeMethods.Point(info.rcCaret.Left, info.rcCaret.Top);
        var bottomRight = new NativeMethods.Point(info.rcCaret.Right, info.rcCaret.Bottom);

        if (!NativeMethods.ClientToScreen(info.hwndCaret, ref topLeft) || !NativeMethods.ClientToScreen(info.hwndCaret, ref bottomRight))
        {
            return false;
        }

        var width = Math.Max(1, bottomRight.X - topLeft.X);
        var height = Math.Max(1, bottomRight.Y - topLeft.Y);
        var bounds = new Rectangle(topLeft.X, topLeft.Y, width, height);

        snapshot = new CaretSnapshot(
            IsActive: true,
            Bounds: bounds,
            FocusWindow: info.hwndFocus,
            CaretWindow: info.hwndCaret,
            FocusThreadId: threadId,
            Source: CaretSource.Win32,
            CapturedAt: DateTimeOffset.UtcNow);
        return true;
    }
}

internal sealed class Imm32ImeStateProvider : IImeStateProvider
{
    public ImeSnapshot Read(CaretSnapshot caret)
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
            Mode: ImeStateNormalizer.Normalize(languageId, openStatus, conversionMode),
            LanguageId: languageId,
            OpenStatus: openStatus,
            ConversionMode: conversionMode,
            Source: source,
            CapturedAt: DateTimeOffset.UtcNow);
    }
}

internal sealed class DiagnosticSampler
{
    private readonly ICaretProvider _caretProvider;
    private readonly IImeStateProvider _imeProvider;

    public DiagnosticSampler(ICaretProvider caretProvider, IImeStateProvider imeProvider)
    {
        _caretProvider = caretProvider;
        _imeProvider = imeProvider;
    }

    public string CaptureJson(string trigger)
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
    private bool _disposed;

    public event EventHandler<string>? Signal;

    public WinEventMonitor()
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
        Signal?.Invoke(this, trigger);
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

    internal delegate void WinEventDelegate(nint hWinEventHook, uint eventType, nint hwnd, int idObject, int idChild, uint idEventThread, uint eventTime);

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
}
