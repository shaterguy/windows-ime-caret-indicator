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
    private const UIntPtr IMC_SETCONVERSIONMODE = (UIntPtr)0x0002;
    private const UIntPtr IMC_SETOPENSTATUS = (UIntPtr)0x0006;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;

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
        public KEYBDINPUT ki;
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

    [DllImport("imm32.dll")]
    public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint SendInput(
        uint nInputs,
        INPUT[] pInputs,
        int cbSize);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLengthW(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(
        IntPtr hWnd,
        StringBuilder lpString,
        int nMaxCount);

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

    public static bool SetImeMode(IntPtr edit, bool open, int conversion)
    {
        IntPtr ime = ImmGetDefaultIMEWnd(edit);
        if (ime == IntPtr.Zero)
            return false;

        IntPtr result;
        if (SendMessageTimeoutW(
                ime,
                WM_IME_CONTROL,
                IMC_SETOPENSTATUS,
                open ? new IntPtr(1) : IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                1000,
                out result) == IntPtr.Zero)
        {
            return false;
        }

        if (SendMessageTimeoutW(
                ime,
                WM_IME_CONTROL,
                IMC_SETCONVERSIONMODE,
                new IntPtr(conversion),
                SMTO_ABORTIFHUNG,
                1000,
                out result) == IntPtr.Zero)
        {
            return false;
        }

        return true;
    }

    public static void KeyDown(ushort vk) => SendKeyCore(vk, false);

    public static void KeyUp(ushort vk) => SendKeyCore(vk, true);

    public static void Key(ushort vk)
    {
        SendKeyCore(vk, false);
        SendKeyCore(vk, true);
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
        if (SendInput(1, inputs, Marshal.SizeOf<INPUT>()) != 1)
            throw new InvalidOperationException("SendInput failed.");
    }

    public static string GetText(IntPtr hwnd)
    {
        int length = GetWindowTextLengthW(hwnd);
        var buffer = new StringBuilder(length + 2);
        GetWindowTextW(hwnd, buffer, buffer.Capacity);
        return buffer.ToString();
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

function Focus-TestHost {
    param([IntPtr]$Window)

    if (-not [WiciImeHarness]::SetForegroundWindow($Window)) {
        throw "Unable to foreground the native test host."
    }

    Start-Sleep -Milliseconds 120
}

function Clear-Edit {
    [WiciImeHarness]::KeyDown(0x11) # Ctrl
    [WiciImeHarness]::Key(0x41)     # A
    [WiciImeHarness]::KeyUp(0x11)
    [WiciImeHarness]::Key(0x08)     # Backspace

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
            $null)
        $script:edit -ne [IntPtr]::Zero
    }

    $koreanLayout = [WiciImeHarness]::LoadKoreanLayout()
    if ($koreanLayout -eq [IntPtr]::Zero) {
        throw "LoadKeyboardLayoutW(00000412) failed. Korean input profile is unavailable in this Windows session."
    }

    Focus-TestHost -Window $window

    if (-not [WiciImeHarness]::RequestKoreanLayout($window, $koreanLayout)) {
        throw "WM_INPUTLANGCHANGEREQUEST failed for the native test host."
    }

    Wait-Until -Label "ko-KR input layout on test-host thread" -Condition {
        [WiciImeHarness]::GetLanguageId($edit) -eq 0x0412
    }

    if (-not [WiciImeHarness]::SetImeMode($edit, $true, 0x0001)) {
        throw "Unable to set Microsoft Korean IME to native/open mode."
    }

    Start-Sleep -Milliseconds 150
    $koreanProbe = Invoke-Probe
    if ($koreanProbe.ime.languageId -ne "0x0412" -or
        $koreanProbe.ime.mode -ne "Korean") {
        throw "Korean probe mismatch: $($koreanProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    Focus-TestHost -Window $window
    Clear-Edit
    Type-Keys -VirtualKeys @(0x47, 0x4B, 0x53) # g k s -> 한 on 2-set Korean layout
    [WiciImeHarness]::Key(0x20)                 # commit composition with space

    Wait-Until -Label "actual Hangul text" -Condition {
        [WiciImeHarness]::GetText($edit).StartsWith("한")
    }

    $koreanText = [WiciImeHarness]::GetText($edit)
    Write-Host "Korean mode actual-input PASS: probe=$($koreanProbe.ime.source), text='$koreanText'"

    Focus-TestHost -Window $window
    [WiciImeHarness]::Key(0x15) # VK_HANGUL: actual Korean/English toggle key
    Start-Sleep -Milliseconds 120

    $englishProbe = Invoke-Probe
    if ($englishProbe.ime.languageId -ne "0x0412" -or
        $englishProbe.ime.mode -ne "English") {
        throw "English-after-Hangul-key probe mismatch: $($englishProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    Focus-TestHost -Window $window
    Clear-Edit
    Type-Keys -VirtualKeys @(0x41, 0x42, 0x43)
    [WiciImeHarness]::Key(0x20)

    Wait-Until -Label "actual English text" -Condition {
        [WiciImeHarness]::GetText($edit).StartsWith("abc")
    }

    $englishText = [WiciImeHarness]::GetText($edit)
    Write-Host "English mode actual-input PASS: probe=$($englishProbe.ime.source), text='$englishText'"

    Focus-TestHost -Window $window
    [WiciImeHarness]::Key(0x15)
    Start-Sleep -Milliseconds 120

    $koreanAgainProbe = Invoke-Probe
    if ($koreanAgainProbe.ime.mode -ne "Korean") {
        throw "Korean-after-second-Hangul-key probe mismatch: $($koreanAgainProbe | ConvertTo-Json -Compress -Depth 8)"
    }

    Write-Host "Hangul-key round-trip PASS: Korean -> English -> Korean."
}
finally {
    if ($hostProcess -and -not $hostProcess.HasExited) {
        Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
