using System.Runtime.InteropServices;
using System.Text.Json;

namespace WindowsImeCaretIndicator;

internal static class DiagnosticRunner
{
    private static readonly TextPattern2Bridge CaretResolver = new();
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
    private const uint TfProfileTypeInputProcessor = 0x0001;
    private const uint TfIppmfForProcess = 0x10000000;
    private const uint TfIppmfEnableProfile = 0x00000001;
    private const uint TfIppmfDontCareCurrentInputLanguage = 0x00000004;

    private static readonly Guid TfInputProcessorProfilesClsid =
        new("33C53A50-F456-4884-B049-85FD643ECFED");
    private static readonly Guid KoreanImeClsid =
        new("A028AE76-01B1-46C2-99C4-ACD9858AE02F");
    private static readonly Guid KoreanImeProfileGuid =
        new("B5FE1F02-D5F2-4445-9C03-C568F23C99A1");

    private static readonly Native.WindowProc WindowProc = WndProc;
    private const uint WmWiciQueryImeState = 0x8001;
    private const uint WmWiciInitializeKoreanIme = 0x8002;
    private const uint WmWiciSetImeOpen = 0x8003;
    private static nint _editWindow;

    [ComImport]
    [Guid("71C6E74C-0F28-11D8-A82A-00065B84435C")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITfInputProcessorProfileMgr
    {
        [PreserveSig]
        int ActivateProfile(
            uint profileType,
            ushort languageId,
            ref Guid clsid,
            ref Guid profileGuid,
            nint keyboardLayout,
            uint flags);
    }

    internal static int Run(bool activateKorean = false)
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

        _editWindow = edit;
        _ = Native.SetFocus(edit);

        if (activateKorean)
        {
            ActivateKoreanInput(edit);
            _ = Native.SetFocus(edit);
        }

        while (Native.GetMessageW(out var message, nint.Zero, 0, 0) > 0)
        {
            _ = Native.TranslateMessage(ref message);
            _ = Native.DispatchMessageW(ref message);
        }

        return 0;
    }

    private static void ActivateKoreanInput(nint edit)
    {
        var hkl = Native.LoadKeyboardLayoutW("00000412", Native.KlfActivate);
        if (hkl == nint.Zero)
            throw new InvalidOperationException(
                $"LoadKeyboardLayoutW(ko-KR) failed: {Marshal.GetLastWin32Error()}");

        if (Native.ActivateKeyboardLayout(hkl, 0) == nint.Zero)
            throw new InvalidOperationException(
                $"ActivateKeyboardLayout(ko-KR) failed: {Marshal.GetLastWin32Error()}");

        var languageId = unchecked(
            (ushort)((long)Native.GetKeyboardLayout(0) & 0xffff));
        if (languageId != ImeLogic.KoreanLanguageId)
            throw new InvalidOperationException(
                $"Test host did not activate ko-KR. LanguageId=0x{languageId:X4}");

        ActivateKoreanTsfProfile();

        var himc = Native.ImmGetContext(edit);
        if (himc == nint.Zero)
            throw new InvalidOperationException(
                "Native EDIT has no IMM input context.");

        try
        {
            if (!Native.ImmSetOpenStatus(himc, true))
                throw new InvalidOperationException(
                    "ImmSetOpenStatus(true) failed.");

            if (!Native.ImmSetConversionStatus(
                    himc,
                    ImeLogic.NativeMode,
                    0))
            {
                throw new InvalidOperationException(
                    "ImmSetConversionStatus(native) failed.");
            }
        }
        finally
        {
            _ = Native.ImmReleaseContext(edit, himc);
        }
    }

    private static void ActivateKoreanTsfProfile()
    {
        var type = Type.GetTypeFromCLSID(
            TfInputProcessorProfilesClsid,
            throwOnError: true);

        var instance = Activator.CreateInstance(type!)
            ?? throw new InvalidOperationException(
                "Unable to create TSF input processor profile manager.");

        try
        {
            if (instance is not ITfInputProcessorProfileMgr profileManager)
            {
                throw new InvalidOperationException(
                    "TSF input processor profile manager interface is unavailable.");
            }

            var clsid = KoreanImeClsid;
            var profileGuid = KoreanImeProfileGuid;
            var flags =
                TfIppmfForProcess |
                TfIppmfEnableProfile |
                TfIppmfDontCareCurrentInputLanguage;

            var hr = profileManager.ActivateProfile(
                TfProfileTypeInputProcessor,
                ImeLogic.KoreanLanguageId,
                ref clsid,
                ref profileGuid,
                nint.Zero,
                flags);

            if (hr != 0)
            {
                throw new InvalidOperationException(
                    $"Korean Microsoft IME TSF profile activation failed: HRESULT=0x{hr:X8}.");
            }
        }
        finally
        {
            if (Marshal.IsComObject(instance))
                _ = Marshal.FinalReleaseComObject(instance);
        }
    }

    private static nint QueryImeState()
    {
        var edit = _editWindow;
        if (edit == nint.Zero)
            return nint.Zero;

        var languageId = unchecked(
            (ushort)((long)Native.GetKeyboardLayout(0) & 0xffff));
        var himc = Native.ImmGetContext(edit);
        if (himc == nint.Zero)
            return nint.Zero;

        try
        {
            var open = Native.ImmGetOpenStatus(himc);
            if (!Native.ImmGetConversionStatus(
                    himc,
                    out var conversion,
                    out _))
            {
                return nint.Zero;
            }

            long packed = 1;
            if (open)
                packed |= 1L << 1;
            packed |= (long)languageId << 16;
            packed |= ((long)conversion & 0xffff) << 32;
            return (nint)packed;
        }
        finally
        {
            _ = Native.ImmReleaseContext(edit, himc);
        }
    }

    private static nint SetImeOpen(bool open)
    {
        var edit = _editWindow;
        if (edit == nint.Zero)
            return nint.Zero;

        var himc = Native.ImmGetContext(edit);
        if (himc == nint.Zero)
            return nint.Zero;

        try
        {
            if (!Native.ImmSetOpenStatus(himc, open))
                return nint.Zero;

            _ = Native.SetFocus(edit);
            return (nint)1;
        }
        finally
        {
            _ = Native.ImmReleaseContext(edit, himc);
        }
    }

    private static nint WndProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        if (message == WmWiciQueryImeState)
            return QueryImeState();

        if (message == WmWiciInitializeKoreanIme)
        {
            try
            {
                if (_editWindow == nint.Zero)
                    return nint.Zero;

                ActivateKoreanInput(_editWindow);
                _ = Native.SetFocus(_editWindow);
                return (nint)1;
            }
            catch
            {
                return nint.Zero;
            }
        }

        if (message == WmWiciSetImeOpen)
            return SetImeOpen(wParam != 0);

        if (message == Native.WmDestroy)
        {
            Native.PostQuitMessage(0);
            return nint.Zero;
        }

        return Native.DefWindowProcW(hwnd, message, wParam, lParam);
    }
}
