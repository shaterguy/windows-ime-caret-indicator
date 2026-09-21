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
    private const uint WM_WICI_QUERY_IME_STATE = 0x8001;
    private const uint WM_WICI_INITIALIZE_KOREAN_IME = 0x8002;
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_SCANCODE = 0x0008;

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

    [DllImport("user32.dll", SetLastError = true)]
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

function Type-ScanCodes {
    param([ushort[]]$ScanCodes)

    foreach ($scanCode in $ScanCodes) {
        [WiciImeHarness]::ScanKey($scanCode)
        Start-Sleep -Milliseconds 20
    }
}

if (-not (Test-Path $ExecutablePath)) {
    throw "Executable was not found at '$ExecutablePath'."
}

$hostProcess = Start-Process -FilePath $ExecutablePath -ArgumentList "--test-host-korean" -PassThru
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

    if (-not [WiciImeHarness]::InitializeKoreanIme($window)) {
        throw "Unable to initialize Korean IME inside the target test-host thread."
    }

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
    Type-ScanCodes -ScanCodes @(0x22, 0x25, 0x1F) # physical G K S -> 한 on 2-set Korean layout
    [WiciImeHarness]::Key(0x20)                 # commit composition with space

    try {
        Wait-Until -Label "actual Hangul text" -Condition {
            $text = [WiciImeHarness]::GetText($edit)
            $text -ne $beforeKoreanText -and $text.Contains("한")
        }
    }
    catch {
        $failedText = [WiciImeHarness]::GetText($edit)
        $failedProbe = Invoke-Probe
        throw "Actual Hangul input failed. Text='$failedText'. Probe=$($failedProbe | ConvertTo-Json -Compress -Depth 8)"
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

    Focus-TestHost -Window $window
    $beforeEnglishText = [WiciImeHarness]::GetText($edit)
    Type-ScanCodes -ScanCodes @(0x1E, 0x30, 0x2E) # physical A B C
    [WiciImeHarness]::Key(0x20)

    try {
        Wait-Until -Label "actual English text" -Condition {
            $text = [WiciImeHarness]::GetText($edit)
            $text -ne $beforeEnglishText -and $text.Contains("abc")
        }
    }
    catch {
        $failedText = [WiciImeHarness]::GetText($edit)
        $failedProbe = Invoke-Probe
        throw "Actual English input failed. Text='$failedText'. Probe=$($failedProbe | ConvertTo-Json -Compress -Depth 8)"
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
