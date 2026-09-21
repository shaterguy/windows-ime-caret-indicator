param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WiciImeHarness
{
    private const uint KLF_ACTIVATE = 0x00000001;
    private const uint WM_INPUTLANGCHANGEREQUEST = 0x0050;
    private const uint WM_IME_CONTROL = 0x0283;
    private static readonly UIntPtr IMC_SETCONVERSIONMODE = (UIntPtr)0x0002;
    private static readonly UIntPtr IMC_SETOPENSTATUS = (UIntPtr)0x0006;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private const uint WM_SETTEXT = 0x000C;
    private const uint WM_GETTEXT = 0x000D;
    private const uint WM_GETTEXTLENGTH = 0x000E;
    private const uint WM_WICI_QUERY_IME_STATE = 0x8001;
    private const uint WM_WICI_INITIALIZE_KOREAN_IME = 0x8002;
    private const uint WM_WICI_INITIALIZE_ENGLISH_INPUT = 0x8003;
    private const uint WM_WICI_QUERY_INPUT_DIAGNOSTIC = 0x8004;
    private const uint WM_WICI_RESET_INPUT_DIAGNOSTICS = 0x8005;
    private const uint WM_WICI_FOCUS_EDIT = 0x8006;
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_SCANCODE = 0x0008;
    private const int UOI_NAME = 2;
    private const uint DESKTOP_READOBJECTS = 0x0001;
    private const uint WM_KEYDOWN = 0x0100;
    private const uint WM_KEYUP = 0x0101;
    private const uint MAPVK_VK_TO_VSC = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public MOUSEINPUT mi;

        [FieldOffset(0)]
        public KEYBDINPUT ki;

        [FieldOffset(0)]
        public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO
    {
        public uint cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(
        IntPtr parent,
        IntPtr childAfter,
        string className,
        string windowName);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(
        uint idThread,
        ref GUITHREADINFO info);

    [DllImport("user32.dll")]
    public static extern IntPtr GetKeyboardLayout(uint idThread);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadKeyboardLayoutW(string pwszKLID, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutW(
        IntPtr hWnd,
        uint msg,
        UIntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out IntPtr result);

    [DllImport(
        "user32.dll",
        EntryPoint = "SendMessageTimeoutW",
        CharSet = CharSet.Unicode,
        SetLastError = true,
        ExactSpelling = true)]
    private static extern IntPtr SendMessageTimeoutStringW(
        IntPtr hWnd,
        uint msg,
        UIntPtr wParam,
        string lParam,
        uint flags,
        uint timeout,
        out IntPtr result);

    [DllImport(
        "user32.dll",
        EntryPoint = "SendMessageTimeoutW",
        CharSet = CharSet.Unicode,
        SetLastError = true,
        ExactSpelling = true)]
    private static extern IntPtr SendMessageTimeoutBufferW(
        IntPtr hWnd,
        uint msg,
        UIntPtr wParam,
        StringBuilder lParam,
        uint flags,
        uint timeout,
        out IntPtr result);

    [DllImport("imm32.dll")]
    public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetProcessWindowStation();

    [DllImport("user32.dll")]
    private static extern IntPtr GetThreadDesktop(uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(
        uint dwFlags,
        [MarshalAs(UnmanagedType.Bool)] bool fInherit,
        uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserObjectInformationW(
        IntPtr hObj,
        int nIndex,
        StringBuilder pvInfo,
        uint nLength,
        out uint lpnLengthNeeded);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ProcessIdToSessionId(
        uint dwProcessId,
        out uint pSessionId);

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessageW(
        IntPtr hWnd,
        uint msg,
        UIntPtr wParam,
        IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKeyW(uint uCode, uint uMapType);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(
        uint nInputs,
        INPUT[] pInputs,
        int cbSize);

    public static IntPtr LoadKoreanLayout()
    {
        return LoadKeyboardLayoutW("00000412", KLF_ACTIVATE);
    }

    public static bool RequestKoreanLayout(IntPtr topWindow, IntPtr hkl)
    {
        IntPtr result;
        return SendMessageTimeoutW(
            topWindow,
            WM_INPUTLANGCHANGEREQUEST,
            UIntPtr.Zero,
            hkl,
            SMTO_ABORTIFHUNG,
            1000,
            out result) != IntPtr.Zero;
    }

    public static ushort GetLanguageId(IntPtr hwnd)
    {
        uint pid;
        uint thread = GetWindowThreadProcessId(hwnd, out pid);
        long hkl = GetKeyboardLayout(thread).ToInt64();
        return unchecked((ushort)(hkl & 0xffff));
    }

    public static bool InitializeKoreanIme(IntPtr topWindow)
    {
        IntPtr result;
        IntPtr transport = SendMessageTimeoutW(
            topWindow,
            WM_WICI_INITIALIZE_KOREAN_IME,
            UIntPtr.Zero,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        return transport != IntPtr.Zero && result != IntPtr.Zero;
    }

    public static bool InitializeEnglishInput(IntPtr topWindow)
    {
        IntPtr result;
        IntPtr transport = SendMessageTimeoutW(
            topWindow,
            WM_WICI_INITIALIZE_ENGLISH_INPUT,
            UIntPtr.Zero,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        return transport != IntPtr.Zero && result != IntPtr.Zero;
    }

    public static long QueryImeState(IntPtr topWindow)
    {
        IntPtr result;
        IntPtr transport = SendMessageTimeoutW(
            topWindow,
            WM_WICI_QUERY_IME_STATE,
            UIntPtr.Zero,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        if (transport == IntPtr.Zero || result == IntPtr.Zero)
            throw new InvalidOperationException("Unable to query target-process IME state.");
        return result.ToInt64();
    }

    private static long QueryInputDiagnostic(IntPtr topWindow, uint selector)
    {
        IntPtr result;
        IntPtr transport = SendMessageTimeoutW(
            topWindow,
            WM_WICI_QUERY_INPUT_DIAGNOSTIC,
            (UIntPtr)selector,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        if (transport == IntPtr.Zero)
            throw new InvalidOperationException(
                "Unable to query target-process input diagnostics. Selector=" + selector + ".");
        return result.ToInt64();
    }

    public static bool ResetInputDiagnostics(IntPtr topWindow)
    {
        IntPtr result;
        IntPtr transport = SendMessageTimeoutW(
            topWindow,
            WM_WICI_RESET_INPUT_DIAGNOSTICS,
            UIntPtr.Zero,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        return transport != IntPtr.Zero && result != IntPtr.Zero;
    }

    public static bool FocusEdit(IntPtr topWindow)
    {
        IntPtr result;
        IntPtr transport = SendMessageTimeoutW(
            topWindow,
            WM_WICI_FOCUS_EDIT,
            UIntPtr.Zero,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        return transport != IntPtr.Zero && result != IntPtr.Zero;
    }

    public static string GetInputDiagnostics(IntPtr topWindow)
    {
        return "queueKeyDown=" + QueryInputDiagnostic(topWindow, 1) +
               ", queueKeyUp=" + QueryInputDiagnostic(topWindow, 2) +
               ", queueChar=" + QueryInputDiagnostic(topWindow, 3) +
               ", translatedKeyDown=" + QueryInputDiagnostic(topWindow, 4) +
               ", dispatchedKeyDown=" + QueryInputDiagnostic(topWindow, 5) +
               ", dispatchedKeyUp=" + QueryInputDiagnostic(topWindow, 6) +
               ", dispatchedChar=" + QueryInputDiagnostic(topWindow, 7);
    }

    public static bool IsTopWindowActive(IntPtr topWindow)
    {
        uint pid;
        uint thread = GetWindowThreadProcessId(topWindow, out pid);
        var info = new GUITHREADINFO
        {
            cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>()
        };
        if (!GetGUIThreadInfo(thread, ref info))
            return false;

        return GetForegroundWindow() == topWindow &&
               info.hwndActive == topWindow;
    }

    public static bool IsInputRoutedToEdit(IntPtr topWindow, IntPtr edit)
    {
        uint pid;
        uint thread = GetWindowThreadProcessId(topWindow, out pid);
        var info = new GUITHREADINFO
        {
            cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>()
        };
        if (!GetGUIThreadInfo(thread, ref info))
            return false;

        return GetForegroundWindow() == topWindow &&
               info.hwndActive == topWindow &&
               info.hwndFocus == edit;
    }

    public static string GetInputRoutingEvidence(IntPtr topWindow, IntPtr edit)
    {
        uint pid;
        uint thread = GetWindowThreadProcessId(topWindow, out pid);
        var info = new GUITHREADINFO
        {
            cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>()
        };
        if (!GetGUIThreadInfo(thread, ref info))
        {
            return "thread=" + thread +
                   ", GetGUIThreadInfo=false, win32=" + Marshal.GetLastWin32Error() +
                   ", foreground=" + GetForegroundWindow().ToInt64() +
                   ", targetTop=" + topWindow.ToInt64() +
                   ", targetEdit=" + edit.ToInt64();
        }

        return "thread=" + thread +
               ", foreground=" + GetForegroundWindow().ToInt64() +
               ", active=" + info.hwndActive.ToInt64() +
               ", focus=" + info.hwndFocus.ToInt64() +
               ", caret=" + info.hwndCaret.ToInt64() +
               ", targetTop=" + topWindow.ToInt64() +
               ", targetEdit=" + edit.ToInt64();
    }

    private static string GetUserObjectName(IntPtr handle)
    {
        if (handle == IntPtr.Zero)
            return "<null>";

        uint required;
        GetUserObjectInformationW(
            handle,
            UOI_NAME,
            null,
            0,
            out required);
        if (required == 0)
            return "<unavailable win32=" + Marshal.GetLastWin32Error() + ">";

        var buffer = new StringBuilder((int)required);
        if (!GetUserObjectInformationW(
                handle,
                UOI_NAME,
                buffer,
                required,
                out required))
        {
            return "<unavailable win32=" + Marshal.GetLastWin32Error() + ">";
        }

        return buffer.ToString();
    }

    public static string GetExecutionEnvironmentEvidence()
    {
        string processWindowStation =
            GetUserObjectName(GetProcessWindowStation());
        string threadDesktop =
            GetUserObjectName(GetThreadDesktop(GetCurrentThreadId()));

        IntPtr inputDesktop = OpenInputDesktop(
            0,
            false,
            DESKTOP_READOBJECTS);
        string inputDesktopName;
        if (inputDesktop == IntPtr.Zero)
        {
            inputDesktopName =
                "<unavailable win32=" + Marshal.GetLastWin32Error() + ">";
        }
        else
        {
            try
            {
                inputDesktopName = GetUserObjectName(inputDesktop);
            }
            finally
            {
                CloseDesktop(inputDesktop);
            }
        }

        uint processSession;
        string processSessionText =
            ProcessIdToSessionId(GetCurrentProcessId(), out processSession)
                ? processSession.ToString()
                : "<unavailable win32=" + Marshal.GetLastWin32Error() + ">";

        uint activeConsoleSession = WTSGetActiveConsoleSessionId();

        return "processWindowStation=" + processWindowStation +
               ", threadDesktop=" + threadDesktop +
               ", inputDesktop=" + inputDesktopName +
               ", processSession=" + processSessionText +
               ", activeConsoleSession=" + activeConsoleSession;
    }

    public static void PostKeyMessage(IntPtr hwnd, ushort vk)
    {
        uint scanCode = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
        uint keyDownLParam = 1u | ((scanCode & 0xffu) << 16);
        uint keyUpLParam = keyDownLParam | 0xC0000000u;

        if (!PostMessageW(
                hwnd,
                WM_KEYDOWN,
                (UIntPtr)vk,
                new IntPtr(unchecked((int)keyDownLParam))))
        {
            throw new InvalidOperationException(
                "PostMessageW(WM_KEYDOWN) failed. Win32=" +
                Marshal.GetLastWin32Error() + ".");
        }

        if (!PostMessageW(
                hwnd,
                WM_KEYUP,
                (UIntPtr)vk,
                new IntPtr(unchecked((int)keyUpLParam))))
        {
            throw new InvalidOperationException(
                "PostMessageW(WM_KEYUP) failed. Win32=" +
                Marshal.GetLastWin32Error() + ".");
        }
    }

    public static bool SetImeMode(IntPtr edit, bool open, int conversion)
    {
        IntPtr ime = ImmGetDefaultIMEWnd(edit);
        if (ime == IntPtr.Zero)
            return false;

        IntPtr result;
        IntPtr transport = SendMessageTimeoutW(
            ime,
            WM_IME_CONTROL,
            IMC_SETOPENSTATUS,
            open ? new IntPtr(1) : IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        if (transport == IntPtr.Zero || result != IntPtr.Zero)
            return false;

        transport = SendMessageTimeoutW(
            ime,
            WM_IME_CONTROL,
            IMC_SETCONVERSIONMODE,
            new IntPtr(conversion),
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        return transport != IntPtr.Zero && result == IntPtr.Zero;
    }

    public static void KeyDown(ushort vk) => SendKeyCore(vk, false);

    public static void KeyUp(ushort vk) => SendKeyCore(vk, true);

    public static void Key(ushort vk)
    {
        SendKeyCore(vk, false);
        SendKeyCore(vk, true);
    }

    public static void ScanKey(ushort scanCode)
    {
        SendScanKeyCore(scanCode, false);
        SendScanKeyCore(scanCode, true);
    }

    private static void SendKeyCore(ushort vk, bool keyUp)
    {
        var input = new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    wScan = 0,
                    dwFlags = keyUp ? KEYEVENTF_KEYUP : 0,
                    time = 0,
                    dwExtraInfo = UIntPtr.Zero
                }
            }
        };

        var inputs = new[] { input };
        int inputSize = Marshal.SizeOf<INPUT>();
        if (SendInput(1, inputs, inputSize) != 1)
        {
            throw new InvalidOperationException(
                $"SendInput failed. Win32={Marshal.GetLastWin32Error()}, cbSize={inputSize}.");
        }
    }

    private static void SendScanKeyCore(ushort scanCode, bool keyUp)
    {
        var input = new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = 0,
                    wScan = scanCode,
                    dwFlags = KEYEVENTF_SCANCODE |
                              (keyUp ? KEYEVENTF_KEYUP : 0),
                    time = 0,
                    dwExtraInfo = UIntPtr.Zero
                }
            }
        };

        var inputs = new[] { input };
        int inputSize = Marshal.SizeOf<INPUT>();
        if (SendInput(1, inputs, inputSize) != 1)
        {
            throw new InvalidOperationException(
                $"SendInput(scan) failed. Win32={Marshal.GetLastWin32Error()}, cbSize={inputSize}.");
        }
    }

    public static string GetText(IntPtr hwnd)
    {
        IntPtr lengthResult;
        IntPtr lengthTransport = SendMessageTimeoutW(
            hwnd,
            WM_GETTEXTLENGTH,
            UIntPtr.Zero,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            1000,
            out lengthResult);
        if (lengthTransport == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                "WM_GETTEXTLENGTH timed out or failed. Win32=" +
                Marshal.GetLastWin32Error() + ".");
        }

        long length = lengthResult.ToInt64();
        if (length < 0 || length > int.MaxValue - 1)
        {
            throw new InvalidOperationException(
                "WM_GETTEXTLENGTH returned an invalid length: " + length + ".");
        }

        var buffer = new StringBuilder((int)length + 1);
        IntPtr readResult;
        IntPtr readTransport = SendMessageTimeoutBufferW(
            hwnd,
            WM_GETTEXT,
            (UIntPtr)(uint)buffer.Capacity,
            buffer,
            SMTO_ABORTIFHUNG,
            1000,
            out readResult);
        if (readTransport == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                "WM_GETTEXT timed out or failed. Win32=" +
                Marshal.GetLastWin32Error() + ".");
        }

        return buffer.ToString();
    }

    public static bool SetText(IntPtr hwnd, string text)
    {
        IntPtr result;
        IntPtr transport = SendMessageTimeoutStringW(
            hwnd,
            WM_SETTEXT,
            UIntPtr.Zero,
            text ?? string.Empty,
            SMTO_ABORTIFHUNG,
            1000,
            out result);
        return transport != IntPtr.Zero && result != IntPtr.Zero;
    }
}
"@

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,
        [int]$TimeoutMs = 6000
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 50
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMs)

    throw "Timed out waiting for $Label."
}

function Invoke-Probe {
    $output = & $ExecutablePath --probe-once
    if ($LASTEXITCODE -ne 0) {
        throw "Probe exited with code $LASTEXITCODE. Output: $output"
    }

    $line = $output | Select-Object -Last 1
    return $line | ConvertFrom-Json
}

function Get-TargetImeState {
    param([IntPtr]$Window)

    [long]$packed = [WiciImeHarness]::QueryImeState($Window)
    $languageId = [int](($packed -shr 16) -band 0xffff)
    $conversion = [uint32](($packed -shr 32) -band 0xffff)
    $open = (($packed -band 2) -ne 0)

    if ($languageId -ne 0x0412) {
        $mode = "English"
    }
    elseif (-not $open) {
        $mode = "English"
    }
    elseif (($conversion -band 0x0001) -ne 0) {
        $mode = "Korean"
    }
    else {
        $mode = "English"
    }

    [pscustomobject]@{
        languageId = ('0x{0:X4}' -f $languageId)
        open = $open
        conversion = [int]$conversion
        mode = $mode
    }
}

function Focus-TestHost {
    param([IntPtr]$Window)

    try {
        Wait-Until -Label "native test-host foreground and EDIT keyboard focus" -TimeoutMs 2000 -Condition {
            $foregroundRequested =
                [WiciImeHarness]::SetForegroundWindow($Window)

            if (-not $foregroundRequested -and
                -not [WiciImeHarness]::IsTopWindowActive($Window)) {
                return $false
            }

            if (-not [WiciImeHarness]::FocusEdit($Window)) {
                return $false
            }

            [WiciImeHarness]::IsInputRoutedToEdit(
                $Window,
                $script:edit)
        }
    }
    catch {
        $routing = [WiciImeHarness]::GetInputRoutingEvidence(
            $Window,
            $script:edit)
        throw "Native test-host focus routing mismatch after bounded reacquisition. $routing $($_.Exception.Message)"
    }
}

function Initialize-KoreanIme {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Window,
        [int]$MaxAttempts = 3
    )

    $attemptEvidence = @()

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Focus-TestHost -Window $Window

        $requestSucceeded =
            [WiciImeHarness]::InitializeKoreanIme($Window)

        if ($requestSucceeded) {
            try {
                Wait-Until -Label "target-thread Korean IME state on attempt $attempt" -TimeoutMs 1500 -Condition {
                    if (-not [WiciImeHarness]::IsInputRoutedToEdit(
                            $Window,
                            $script:edit)) {
                        return $false
                    }

                    $state = Get-TargetImeState -Window $Window
                    [WiciImeHarness]::GetLanguageId($script:edit) -eq 0x0412 -and
                    $state.languageId -eq "0x0412" -and
                    $state.mode -eq "Korean"
                }

                return
            }
            catch {
                $attemptEvidence +=
                    "attempt=$attempt request=true state-not-ready"
            }
        }
        else {
            $attemptEvidence +=
                "attempt=$attempt request=false"
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Milliseconds 100
        }
    }

    $lastState = $null
    try {
        $lastState = Get-TargetImeState -Window $Window
    }
    catch {
        $lastState = [pscustomobject]@{
            queryError = $_.Exception.Message
        }
    }

    $routing = [WiciImeHarness]::GetInputRoutingEvidence(
        $Window,
        $script:edit)
    throw "Unable to initialize and observe Korean IME inside the target test-host thread after $MaxAttempts bounded attempts. Attempts=$($attemptEvidence -join '; '). LastTarget=$($lastState | ConvertTo-Json -Compress). Routing=$routing"
}

function Clear-Edit {
    if (-not [WiciImeHarness]::SetText(
            $script:edit,
            "")) {
        throw "Unable to reset native EDIT text."
    }

    Wait-Until -Label "empty edit control" -Condition {
        [WiciImeHarness]::GetText($script:edit).Length -eq 0
    }
}

function Type-Keys {
    param([ushort[]]$VirtualKeys)

    foreach ($vk in $VirtualKeys) {
        [WiciImeHarness]::Key($vk)
        Start-Sleep -Milliseconds 20
    }
}

function Type-ScanCodes {
    param([ushort[]]$ScanCodes)

    foreach ($scanCode in $ScanCodes) {
        [WiciImeHarness]::ScanKey($scanCode)
        Start-Sleep -Milliseconds 20
    }
}

function Test-TextContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Needle,
        [int]$TimeoutMs = 1500
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ([WiciImeHarness]::GetText(
                $script:edit).Contains($Needle)) {
            return $true
        }
        Start-Sleep -Milliseconds 50
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMs)

    return $false
}

function Type-InputPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("ScanCode", "VirtualKey")]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [ushort[]]$VirtualKeys,
        [Parameter(Mandatory = $true)]
        [ushort[]]$ScanCodes
    )

    if ($Path -eq "ScanCode") {
        Type-ScanCodes -ScanCodes $ScanCodes
    }
    else {
        Type-Keys -VirtualKeys $VirtualKeys
    }
}

function Commit-InputPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("ScanCode", "VirtualKey")]
        [string]$Path
    )

    if ($Path -eq "ScanCode") {
        [WiciImeHarness]::ScanKey(0x39)
    }
    else {
        [WiciImeHarness]::Key(0x20)
    }
}

if (-not (Test-Path $ExecutablePath)) {
    throw "Executable was not found at '$ExecutablePath'."
}

$hostProcess = Start-Process -FilePath $ExecutablePath -ArgumentList "--test-host" -PassThru
$script:edit = [IntPtr]::Zero

try {
    $window = [IntPtr]::Zero
    Wait-Until -Label "native test host window" -Condition {
        $script:window = [WiciImeHarness]::FindWindowW(
            "WiciTestHost",
            "Windows IME Caret Indicator Test Host")
        $script:window -ne [IntPtr]::Zero
    }
    $window = $script:window

    Wait-Until -Label "native EDIT control" -Condition {
        $script:edit = [WiciImeHarness]::FindWindowExW(
            $window,
            [IntPtr]::Zero,
            "EDIT",
            "Type here and move the caret")
        $script:edit -ne [IntPtr]::Zero
    }

    Focus-TestHost -Window $window

    if (-not [WiciImeHarness]::InitializeEnglishInput($window)) {
        throw "Unable to initialize en-US input inside the target test-host thread."
    }
    try {
        Wait-Until -Label "target-process en-US English baseline" -Condition {
            $state = Get-TargetImeState -Window $window
            $state.languageId -eq "0x0409" -and
            $state.mode -eq "English"
        }
    }
    catch {
        $lastTargetState = Get-TargetImeState -Window $window
        throw "Target-process en-US English baseline did not become observable. LastTarget=$($lastTargetState | ConvertTo-Json -Compress). $($_.Exception.Message)"
    }
    $targetEnglishBaseline = Get-TargetImeState -Window $window
    $englishBaselineProbe = Invoke-Probe
    if ($englishBaselineProbe.ime.languageId -ne "0x0409" -or
        $englishBaselineProbe.ime.mode -ne "English") {
        throw "English baseline target/product mismatch. Target=$($targetEnglishBaseline | ConvertTo-Json -Compress) Probe=$($englishBaselineProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    Clear-Edit
    Focus-TestHost -Window $window
    if (-not [WiciImeHarness]::ResetInputDiagnostics($window)) {
        throw "Unable to reset target-process input diagnostics before scan-code SendInput."
    }
    Type-ScanCodes -ScanCodes @(0x1E, 0x30, 0x2E)
    if (Test-TextContains -Needle "abc") {
        $inputPath = "ScanCode"
    }
    else {
        $scanFailureText = [WiciImeHarness]::GetText($edit)
        $scanDiagnostics = [WiciImeHarness]::GetInputDiagnostics($window)

        Clear-Edit
        Focus-TestHost -Window $window
        if (-not [WiciImeHarness]::ResetInputDiagnostics($window)) {
            throw "Unable to reset target-process input diagnostics before virtual-key SendInput."
        }
        Type-Keys -VirtualKeys @(0x41, 0x42, 0x43)
        if (-not (Test-TextContains -Needle "abc")) {
            $virtualFailureText = [WiciImeHarness]::GetText($edit)
            $virtualDiagnostics = [WiciImeHarness]::GetInputDiagnostics($window)
            $routing = [WiciImeHarness]::GetInputRoutingEvidence(
                $window,
                $edit)
            $executionEnvironment =
                [WiciImeHarness]::GetExecutionEnvironmentEvidence()

            Clear-Edit
            Focus-TestHost -Window $window
            if (-not [WiciImeHarness]::ResetInputDiagnostics($window)) {
                throw "Unable to reset target-process input diagnostics before diagnostic PostMessage input."
            }
            [WiciImeHarness]::PostKeyMessage($edit, 0x41)
            [WiciImeHarness]::PostKeyMessage($edit, 0x42)
            [WiciImeHarness]::PostKeyMessage($edit, 0x43)
            $postMessageDelivered =
                Test-TextContains -Needle "abc"
            $postMessageText = [WiciImeHarness]::GetText($edit)
            $postMessageDiagnostics =
                [WiciImeHarness]::GetInputDiagnostics($window)

            if ($postMessageDelivered) {
                throw "Keyboard SendInput delivery failed in English baseline for both scan-code and virtual-key paths, while the diagnostic window-scoped PostMessage path produced 'abc'. PostMessage remains diagnostic only and is not actual-input proof. Target-side counters distinguish queue delivery, TranslateMessage character generation, and dispatch to the EDIT HWND. ScanText='$scanFailureText'. ScanDiagnostics=$scanDiagnostics. VirtualText='$virtualFailureText'. VirtualDiagnostics=$virtualDiagnostics. PostMessageText='$postMessageText'. PostMessageDiagnostics=$postMessageDiagnostics. Routing=$routing. ExecutionEnvironment=$executionEnvironment"
            }

            throw "Keyboard SendInput delivery failed in English baseline for both scan-code and virtual-key paths, and the diagnostic window-scoped PostMessage path also failed to produce 'abc'. Target-side counters now distinguish queue delivery, TranslateMessage character generation, and dispatch to the EDIT HWND. ScanText='$scanFailureText'. ScanDiagnostics=$scanDiagnostics. VirtualText='$virtualFailureText'. VirtualDiagnostics=$virtualDiagnostics. PostMessageText='$postMessageText'. PostMessageDiagnostics=$postMessageDiagnostics. Routing=$routing. ExecutionEnvironment=$executionEnvironment"
        }

        $inputPath = "VirtualKey"
        Write-Host "English input baseline: scan-code path unavailable on this runner; virtual-key SendInput reached the focused EDIT. Continuing actual IME validation with VirtualKey path."
    }

    Write-Host "English input baseline PASS: inputPath=$inputPath, target=$($targetEnglishBaseline | ConvertTo-Json -Compress)"
    Clear-Edit
    Focus-TestHost -Window $window

    Initialize-KoreanIme -Window $window

    Wait-Until -Label "ko-KR input layout on test-host thread" -Condition {
        [WiciImeHarness]::GetLanguageId($edit) -eq 0x0412
    }

    $targetKorean = Get-TargetImeState -Window $window
    if ($targetKorean.languageId -ne "0x0412" -or
        $targetKorean.mode -ne "Korean") {
        throw "Target-process Korean setup mismatch: $($targetKorean | ConvertTo-Json -Compress)"
    }

    Start-Sleep -Milliseconds 120
    $initialProbe = Invoke-Probe
    if ($initialProbe.ime.languageId -ne "0x0412" -or
        $initialProbe.ime.mode -ne "Korean") {
        throw "Cross-process Korean probe mismatch. Target=$($targetKorean | ConvertTo-Json -Compress) Probe=$($initialProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    $koreanProbe = $initialProbe

    Focus-TestHost -Window $window
    $beforeKoreanText = [WiciImeHarness]::GetText($edit)
    Type-InputPath -Path $inputPath -VirtualKeys @(0x47, 0x4B, 0x53) -ScanCodes @(0x22, 0x25, 0x1F)
    Commit-InputPath -Path $inputPath

    try {
        Wait-Until -Label "actual Hangul text" -Condition {
            $text = [WiciImeHarness]::GetText($edit)
            $text -ne $beforeKoreanText -and $text.Contains("한")
        }
    }
    catch {
        $failedText = [WiciImeHarness]::GetText($edit)
        $failedProbe = Invoke-Probe
        $routing = [WiciImeHarness]::GetInputRoutingEvidence(
            $window,
            $edit)
        throw "Actual Hangul input failed. InputPath=$inputPath. Text='$failedText'. Routing=$routing. Probe=$($failedProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    $koreanText = [WiciImeHarness]::GetText($edit)
    Write-Host "Korean mode actual-input PASS: probe=$($koreanProbe.ime.source), text='$koreanText'"

    Focus-TestHost -Window $window
    [WiciImeHarness]::Key(0x15) # VK_HANGUL: actual Korean/English toggle key
    Start-Sleep -Milliseconds 120

    $targetEnglish = Get-TargetImeState -Window $window
    if ($targetEnglish.mode -ne "English") {
        throw "Target-process Hangul-key toggle did not enter English mode: $($targetEnglish | ConvertTo-Json -Compress)"
    }

    $englishProbe = Invoke-Probe
    if ($englishProbe.ime.languageId -ne "0x0412" -or
        $englishProbe.ime.mode -ne "English") {
        throw "English-after-Hangul-key probe mismatch. Target=$($targetEnglish | ConvertTo-Json -Compress) Probe=$($englishProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    Clear-Edit
    Focus-TestHost -Window $window
    $beforeEnglishText = [WiciImeHarness]::GetText($edit)
    Type-InputPath -Path $inputPath -VirtualKeys @(0x41, 0x42, 0x43) -ScanCodes @(0x1E, 0x30, 0x2E)

    try {
        Wait-Until -Label "actual English text" -Condition {
            $text = [WiciImeHarness]::GetText($edit)
            $text -ne $beforeEnglishText -and $text.Contains("abc")
        }
    }
    catch {
        $failedText = [WiciImeHarness]::GetText($edit)
        $failedProbe = Invoke-Probe
        $routing = [WiciImeHarness]::GetInputRoutingEvidence(
            $window,
            $edit)
        throw "Actual English input failed. InputPath=$inputPath. Text='$failedText'. Routing=$routing. Probe=$($failedProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    $englishText = [WiciImeHarness]::GetText($edit)
    Write-Host "English mode actual-input PASS: probe=$($englishProbe.ime.source), text='$englishText'"

    Focus-TestHost -Window $window
    [WiciImeHarness]::Key(0x15)
    Start-Sleep -Milliseconds 120

    $targetKoreanAgain = Get-TargetImeState -Window $window
    if ($targetKoreanAgain.mode -ne "Korean") {
        throw "Target-process second Hangul-key toggle did not return to Korean mode: $($targetKoreanAgain | ConvertTo-Json -Compress)"
    }

    $koreanAgainProbe = Invoke-Probe
    if ($koreanAgainProbe.ime.mode -ne "Korean") {
        throw "Korean-after-second-Hangul-key probe mismatch. Target=$($targetKoreanAgain | ConvertTo-Json -Compress) Probe=$($koreanAgainProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    Write-Host "Hangul-key round-trip PASS: Korean -> English -> Korean."
}
finally {
    if ($hostProcess -and -not $hostProcess.HasExited) {
        Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
