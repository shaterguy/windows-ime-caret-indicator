param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class WiciWindowSnapshot
{
    public long Handle { get; set; }
    public long ExStyle { get; set; }
    public int Left { get; set; }
    public int Top { get; set; }
    public int Right { get; set; }
    public int Bottom { get; set; }
    public string ClassName { get; set; } = "";
    public string Title { get; set; } = "";
}

public sealed class WiciRectSnapshot
{
    public int Left { get; set; }
    public int Top { get; set; }
    public int Right { get; set; }
    public int Bottom { get; set; }
}

public static class WiciRuntimeNative
{
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
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

    [StructLayout(LayoutKind.Sequential)]
    private struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(
        IntPtr parent,
        EnumWindowsProc callback,
        IntPtr lParam);

    [DllImport("shell32.dll")]
    private static extern int Shell_NotifyIconGetRect(
        ref NOTIFYICONIDENTIFIER identifier,
        out RECT iconLocation);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hwnd, StringBuilder buffer, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder buffer, int maxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(
        IntPtr parent,
        IntPtr childAfter,
        string className,
        string windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(
        IntPtr hwnd,
        uint message,
        IntPtr wParam,
        IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr insertAfter,
        int x,
        int y,
        int cx,
        int cy,
        uint flags);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(
        uint flags,
        uint dx,
        uint dy,
        uint data,
        UIntPtr extraInfo);

    [DllImport("user32.dll")]
    private static extern void keybd_event(
        byte virtualKey,
        byte scanCode,
        uint flags,
        UIntPtr extraInfo);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    public static WiciWindowSnapshot[] GetVisibleTopLevelWindows(int pid)
    {
        var result = new List<WiciWindowSnapshot>();
        EnumWindows((hwnd, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var ownerPid);
            if (ownerPid != (uint)pid || !IsWindowVisible(hwnd))
                return true;

            if (!GetWindowRect(hwnd, out var rect))
                return true;

            var className = new StringBuilder(256);
            var title = new StringBuilder(512);
            GetClassNameW(hwnd, className, className.Capacity);
            GetWindowTextW(hwnd, title, title.Capacity);

            result.Add(new WiciWindowSnapshot
            {
                Handle = hwnd.ToInt64(),
                ExStyle = GetWindowLongPtr(hwnd, -20).ToInt64(),
                Left = rect.Left,
                Top = rect.Top,
                Right = rect.Right,
                Bottom = rect.Bottom,
                ClassName = className.ToString(),
                Title = title.ToString()
            });
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }

    public static IntPtr GetFocusedWindowForForeground()
    {
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero)
            return IntPtr.Zero;

        var thread = GetWindowThreadProcessId(foreground, out _);
        var info = new GUITHREADINFO
        {
            cbSize = (uint)Marshal.SizeOf<GUITHREADINFO>()
        };
        return GetGUIThreadInfo(thread, ref info) ? info.hwndFocus : IntPtr.Zero;
    }

    public static WiciRectSnapshot GetRect(IntPtr hwnd)
    {
        if (!GetWindowRect(hwnd, out var rect))
            throw new InvalidOperationException("GetWindowRect failed.");
        return new WiciRectSnapshot
        {
            Left = rect.Left,
            Top = rect.Top,
            Right = rect.Right,
            Bottom = rect.Bottom
        };
    }

    public static string ReadText(IntPtr hwnd)
    {
        var buffer = new StringBuilder(4096);
        GetWindowTextW(hwnd, buffer, buffer.Capacity);
        return buffer.ToString();
    }

    public static bool MoveNoActivate(IntPtr hwnd, int x, int y)
    {
        const uint SWP_NOSIZE = 0x0001;
        const uint SWP_NOZORDER = 0x0004;
        const uint SWP_NOACTIVATE = 0x0010;
        return SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    public static void Click(int x, int y)
    {
        const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        const uint MOUSEEVENTF_LEFTUP = 0x0004;
        if (!SetCursorPos(x, y))
            throw new InvalidOperationException("SetCursorPos failed.");
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }

    public static void RightClick(int x, int y)
    {
        const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        const uint MOUSEEVENTF_RIGHTUP = 0x0010;
        if (!SetCursorPos(x, y))
            throw new InvalidOperationException("SetCursorPos failed.");
        mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, UIntPtr.Zero);
    }

    public static void SendKey(byte virtualKey)
    {
        const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
        const uint KEYEVENTF_KEYUP = 0x0002;
        var extended =
            virtualKey == 0x21 ||
            virtualKey == 0x22 ||
            virtualKey == 0x23 ||
            virtualKey == 0x24 ||
            virtualKey == 0x25 ||
            virtualKey == 0x26 ||
            virtualKey == 0x27 ||
            virtualKey == 0x28 ||
            virtualKey == 0x2D ||
            virtualKey == 0x2E;
        var flags = extended ? KEYEVENTF_EXTENDEDKEY : 0u;
        keybd_event(virtualKey, 0, flags, UIntPtr.Zero);
        keybd_event(
            virtualKey,
            0,
            flags | KEYEVENTF_KEYUP,
            UIntPtr.Zero);
    }

    public static WiciRectSnapshot FindNotifyIconRect(int pid)
    {
        var windows = new HashSet<IntPtr>();
        EnumWindows((hwnd, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var ownerPid);
            if (ownerPid == (uint)pid)
                windows.Add(hwnd);
            return true;
        }, IntPtr.Zero);

        var hwndMessage = new IntPtr(-3);
        EnumChildWindows(hwndMessage, (hwnd, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var ownerPid);
            if (ownerPid == (uint)pid)
                windows.Add(hwnd);
            return true;
        }, IntPtr.Zero);

        foreach (var hwnd in windows)
        {
            for (uint id = 0; id <= 64; id++)
            {
                var identifier = new NOTIFYICONIDENTIFIER
                {
                    cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(),
                    hWnd = hwnd,
                    uID = id,
                    guidItem = Guid.Empty
                };
                if (Shell_NotifyIconGetRect(ref identifier, out var rect) == 0 &&
                    rect.Right > rect.Left &&
                    rect.Bottom > rect.Top)
                {
                    return new WiciRectSnapshot
                    {
                        Left = rect.Left,
                        Top = rect.Top,
                        Right = rect.Right,
                        Bottom = rect.Bottom
                    };
                }
            }
        }

        return null;
    }
}
"@

function Stop-TrackedProcess {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }

    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            [void]$Process.WaitForExit(5000)
        }
    }
    catch {
    }
}

function Wait-MainWindow {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [int]$Attempts = 80
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "Process $($Process.Id) exited before its main window became available."
        }
        if ($Process.MainWindowHandle -ne 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    }

    throw "Process $($Process.Id) did not expose a main window."
}

function Focus-TestHost {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$HostProcess,
        [Parameter(Mandatory = $true)]
        [object]$Shell
    )

    [void]$Shell.AppActivate($HostProcess.Id)
    Start-Sleep -Milliseconds 150

    $result = [WiciRuntimeNative]::SendMessageW(
        $HostProcess.MainWindowHandle,
        0x8003,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    if ($result -eq [IntPtr]::Zero) {
        throw "Test host did not initialize English input."
    }

    $result = [WiciRuntimeNative]::SendMessageW(
        $HostProcess.MainWindowHandle,
        0x8006,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    if ($result -eq [IntPtr]::Zero) {
        throw "Test host did not focus its edit control."
    }

    Start-Sleep -Milliseconds 150

    $foreground = [WiciRuntimeNative]::GetForegroundWindow()
    $edit = [WiciRuntimeNative]::GetFocusedWindowForForeground()
    if ($foreground -ne $HostProcess.MainWindowHandle -or
        $edit -eq [IntPtr]::Zero) {
        throw "Test host did not retain foreground/edit keyboard focus."
    }

    return $edit
}

function Get-Probe {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.ArgumentList.Add("--probe-once")
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $probeProcess = [System.Diagnostics.Process]::new()
    $probeProcess.StartInfo = $startInfo

    try {
        if (-not $probeProcess.Start()) {
            throw "Caret probe process did not start."
        }

        $stdout = $probeProcess.StandardOutput.ReadToEnd()
        $stderr = $probeProcess.StandardError.ReadToEnd()
        $probeProcess.WaitForExit()

        $output = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $output += ($stdout -split "\r?\n")
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $output += ($stderr -split "\r?\n")
        }

        if ($probeProcess.ExitCode -ne 0) {
            throw "Caret probe failed with exit code $($probeProcess.ExitCode). Output: $($output -join ' | ')"
        }

        $jsonLine = $output |
            Where-Object { $_ -match '^\s*\{' } |
            Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace($jsonLine)) {
            throw "Caret probe did not produce JSON. Output: $($output -join ' | ')"
        }

        return ($jsonLine | ConvertFrom-Json)
    }
    finally {
        $probeProcess.Dispose()
    }
}

function Get-InputDiagnosticSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$HostProcess
    )

    $selectors = [ordered]@{
        queueKeyDown = 1
        queueKeyUp = 2
        queueChar = 3
        translatedKeyDown = 4
        dispatchedKeyDown = 5
        dispatchedKeyUp = 6
        dispatchedChar = 7
    }

    $result = [ordered]@{}
    foreach ($entry in $selectors.GetEnumerator()) {
        $value = [WiciRuntimeNative]::SendMessageW(
            $HostProcess.MainWindowHandle,
            0x8004,
            [IntPtr]$entry.Value,
            [IntPtr]::Zero)
        $result[$entry.Key] = $value.ToInt64()
    }

    return $result
}

function Get-EditAutomationValue {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$EditHandle
    )

    try {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle(
            $EditHandle)
        if ($null -eq $element) {
            return $null
        }

        $rawPattern = $element.GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $rawPattern) {
            return $null
        }

        return ([System.Windows.Automation.ValuePattern]$rawPattern).Current.Value
    }
    catch {
        return $null
    }
}

function Invoke-InputContinuityProbe {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$HostProcess,
        [Parameter(Mandatory = $true)]
        [IntPtr]$EditHandle,
        [Parameter(Mandatory = $true)]
        [object]$Shell,
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $foreground = [WiciRuntimeNative]::GetForegroundWindow()
    $focused = [WiciRuntimeNative]::GetFocusedWindowForForeground()
    if ($foreground -ne $HostProcess.MainWindowHandle -or
        $focused -ne $EditHandle) {
        throw "Input-continuity probe started without target foreground/edit focus."
    }

    $reset = [WiciRuntimeNative]::SendMessageW(
        $HostProcess.MainWindowHandle,
        0x8005,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    if ($reset -eq [IntPtr]::Zero) {
        throw "Unable to reset test-host input diagnostics."
    }

    $Shell.SendKeys("^a")
    $Shell.SendKeys($Text)
    Start-Sleep -Milliseconds 300

    $snapshot = Get-InputDiagnosticSnapshot -HostProcess $HostProcess
    if ($snapshot.queueKeyDown -le 0 -or
        $snapshot.dispatchedKeyDown -le 0 -or
        $snapshot.queueChar -lt $Text.Length -or
        $snapshot.dispatchedChar -lt $Text.Length) {
        throw ("Input messages did not reach and dispatch through the target edit. " +
            ($snapshot | ConvertTo-Json -Compress))
    }

    $automationValue = Get-EditAutomationValue -EditHandle $EditHandle
    if ($null -ne $automationValue -and $automationValue -ne $Text) {
        throw "UI Automation value after typing was '$automationValue' instead of '$Text'."
    }

    return [ordered]@{
        counters = $snapshot
        automationValue = $automationValue
    }
}

function Get-VisibleProductWindows {
    param([System.Diagnostics.Process]$Product)

    $Product.Refresh()
    if ($Product.HasExited) {
        throw "Product process exited unexpectedly."
    }
    return @([WiciRuntimeNative]::GetVisibleTopLevelWindows($Product.Id))
}

function Wait-VisibleOverlay {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Product,
        [int]$Attempts = 60
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        $windows = @(Get-VisibleProductWindows -Product $Product)
        if ($windows.Count -eq 1) {
            return $windows[0]
        }
        if ($windows.Count -gt 1) {
            throw "More than one visible product window exists: $($windows.Count)."
        }
        Start-Sleep -Milliseconds 100
    }

    throw "The released product did not show one visible overlay for an active caret."
}

function Assert-NoVisibleOverlay {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Product
    )

    for ($i = 0; $i -lt 15; $i++) {
        $windows = @(Get-VisibleProductWindows -Product $Product)
        if ($windows.Count -ne 0) {
            throw "Paused state still exposed a visible overlay."
        }
        Start-Sleep -Milliseconds 100
    }
}

function Write-TestSettings {
    param(
        [bool]$StartWithWindows,
        [bool]$Paused,
        [string]$Path
    )

    $dir = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [ordered]@{
        StartWithWindows = $StartWithWindows
        Paused = $Paused
    } | ConvertTo-Json | Set-Content -Path $Path -Encoding UTF8
}

function Wait-RunRegistration {
    param(
        [string]$RunKey,
        [bool]$ExpectedPresent,
        [string]$ExpectedPath = ""
    )

    for ($i = 0; $i -lt 30; $i++) {
        $value = $null
        try {
            $value = Get-ItemPropertyValue -Path $RunKey -Name "WindowsImeCaretIndicator" -ErrorAction Stop
        }
        catch {
        }

        if ($ExpectedPresent) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $normalized = $value.Trim('"')
                if (-not [string]::Equals(
                        [IO.Path]::GetFullPath($normalized),
                        [IO.Path]::GetFullPath($ExpectedPath),
                        [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Startup registration points to '$value' instead of '$ExpectedPath'."
                }
                return $value
            }
        }
        elseif ($null -eq $value) {
            return $null
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Startup registration did not reach the expected state."
}

function Wait-SettingsState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [bool]$StartWithWindows,
        [Parameter(Mandatory = $true)]
        [bool]$Paused
    )

    for ($i = 0; $i -lt 30; $i++) {
        try {
            if (Test-Path $Path) {
                $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
                if ([bool]$settings.StartWithWindows -eq $StartWithWindows -and
                    [bool]$settings.Paused -eq $Paused) {
                    return $settings
                }
            }
        }
        catch {
        }
        Start-Sleep -Milliseconds 100
    }

    throw "Settings did not reach StartWithWindows=$StartWithWindows Paused=$Paused."
}

function Invoke-TrayMenuAction {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Product,
        [Parameter(Mandatory = $true)]
        [object]$Shell,
        [Parameter(Mandatory = $true)]
        [ValidateSet("FirstEnabled", "Startup", "Exit")]
        [string]$Action
    )

    $Product.Refresh()
    if ($Product.HasExited) {
        throw "Product exited before tray action '$Action'."
    }

    $rect = [WiciRuntimeNative]::FindNotifyIconRect($Product.Id)
    if ($null -eq $rect) {
        throw "Unable to locate the product notification-area icon."
    }

    $visibleBeforeOpen = @(Get-VisibleProductWindows -Product $Product)
    $existingHandles = @(
        $visibleBeforeOpen |
            ForEach-Object { [int64]$_.Handle }
    )

    $x = [Math]::Floor(($rect.Left + $rect.Right) / 2)
    $y = [Math]::Floor(($rect.Top + $rect.Bottom) / 2)
    [WiciRuntimeNative]::RightClick($x, $y)

    $visibleAfterOpen = @()
    $popup = $null
    for ($i = 0; $i -lt 30; $i++) {
        $visibleAfterOpen = @(Get-VisibleProductWindows -Product $Product)
        $popup = $visibleAfterOpen |
            Where-Object {
                $existingHandles -notcontains [int64]$_.Handle
            } |
            Select-Object -First 1
        if ($null -ne $popup) {
            break
        }
        Start-Sleep -Milliseconds 50
    }

    if ($null -eq $popup) {
        $beforeSummary = $visibleBeforeOpen |
            Select-Object Handle, ClassName, Title
        $afterSummary = $visibleAfterOpen |
            Select-Object Handle, ClassName, Title
        throw (
            "Tray right-click did not expose a new product popup window. " +
            "before=" +
            ($beforeSummary | ConvertTo-Json -Compress) +
            " after=" +
            ($afterSummary | ConvertTo-Json -Compress))
    }

    if (-not [WiciRuntimeNative]::SetForegroundWindow(
            [IntPtr]([int64]$popup.Handle))) {
        throw (
            "Unable to foreground the tray popup window handle " +
            "$($popup.Handle).")
    }
    Start-Sleep -Milliseconds 100

    switch ($Action) {
        "FirstEnabled" {
            [WiciRuntimeNative]::SendKey(0x24)
            Start-Sleep -Milliseconds 80
            [WiciRuntimeNative]::SendKey(0x0D)
        }
        "Startup" {
            [WiciRuntimeNative]::SendKey(0x23)
            Start-Sleep -Milliseconds 80
            [WiciRuntimeNative]::SendKey(0x26)
            Start-Sleep -Milliseconds 80
            [WiciRuntimeNative]::SendKey(0x0D)
        }
        "Exit" {
            [WiciRuntimeNative]::SendKey(0x23)
            Start-Sleep -Milliseconds 80
            [WiciRuntimeNative]::SendKey(0x0D)
        }
    }

    Start-Sleep -Milliseconds 200
    return [ordered]@{
        action = $Action
        iconRect = [ordered]@{
            left = $rect.Left
            top = $rect.Top
            right = $rect.Right
            bottom = $rect.Bottom
        }
        visibleProductWindowsBeforeOpen = $visibleBeforeOpen.Count
        visibleProductWindowsAfterOpen = $visibleAfterOpen.Count
        popup = [ordered]@{
            handle = $popup.Handle
            className = $popup.ClassName
            title = $popup.Title
        }
        physicalRightClick = $true
        popupWindowObserved = $true
        popupForegrounded = $true
        keyboardNavigation = $true
    }
}

function Wait-NoVisibleOverlay {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Product,
        [int]$Attempts = 40,
        [int]$StableSamples = 4
    )

    $stable = 0
    for ($i = 0; $i -lt $Attempts; $i++) {
        $windows = @(Get-VisibleProductWindows -Product $Product)
        if ($windows.Count -eq 0) {
            $stable++
            if ($stable -ge $StableSamples) {
                return
            }
        }
        else {
            $stable = 0
        }
        Start-Sleep -Milliseconds 50
    }

    throw "A visible product window remained after focus moved to a non-text or paused state."
}

function Measure-OverlayResponseLatency {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Product,
        [Parameter(Mandatory = $true)]
        [object]$Shell,
        [int]$SampleCount = 20
    )

    $Shell.SendKeys("{END}")
    Start-Sleep -Milliseconds 150
    $null = Wait-VisibleOverlay -Product $Product

    $samples = @()
    for ($i = 0; $i -lt $SampleCount; $i++) {
        $before = Wait-VisibleOverlay -Product $Product
        $key = if (($i % 2) -eq 0) { "{HOME}" } else { "{END}" }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $Shell.SendKeys($key)

        $elapsed = $null
        while ($watch.ElapsedMilliseconds -lt 500) {
            $windows = @(Get-VisibleProductWindows -Product $Product)
            if ($windows.Count -gt 1) {
                throw "More than one visible product window appeared during latency measurement."
            }
            if ($windows.Count -eq 1) {
                $current = $windows[0]
                if ($current.Left -ne $before.Left -or
                    $current.Top -ne $before.Top -or
                    $current.Right -ne $before.Right -or
                    $current.Bottom -ne $before.Bottom) {
                    $elapsed = [double]$watch.Elapsed.TotalMilliseconds
                    break
                }
            }
            Start-Sleep -Milliseconds 2
        }
        $watch.Stop()

        if ($null -eq $elapsed) {
            throw "Overlay did not follow a HOME/END caret movement within 500 ms."
        }

        $samples += [Math]::Round($elapsed, 3)
        Start-Sleep -Milliseconds 40
    }

    $sorted = @($samples | Sort-Object)
    $p95Index = [Math]::Max(
        0,
        [Math]::Min(
            $sorted.Count - 1,
            [Math]::Ceiling($sorted.Count * 0.95) - 1))
    $p95 = [double]$sorted[$p95Index]
    $average = [double](($samples | Measure-Object -Average).Average)
    $maximum = [double](($samples | Measure-Object -Maximum).Maximum)

    if ($p95 -gt 100.0) {
        throw "Overlay response p95 exceeded the <=100 ms target: $([Math]::Round($p95, 3)) ms."
    }

    return [ordered]@{
        sampleCount = $samples.Count
        samplesMs = @($samples)
        averageMs = [Math]::Round($average, 3)
        p95Ms = [Math]::Round($p95, 3)
        maxMs = [Math]::Round($maximum, 3)
        targetP95Ms = 100
        passed = $true
    }
}

function Invoke-CaretSoak {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Product,
        [Parameter(Mandatory = $true)]
        [object]$Shell,
        [int]$DurationSeconds = 180
    )

    $Product.Refresh()
    $handlesBefore = $Product.HandleCount
    $privateBefore = $Product.PrivateMemorySize64
    $samples = @()
    $moves = 0
    $maxVisibleOverlays = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextSampleSeconds = 30.0

    while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        if (($moves % 2) -eq 0) {
            $Shell.SendKeys("{LEFT}")
        }
        else {
            $Shell.SendKeys("{RIGHT}")
        }
        if (($moves % 100) -eq 0) {
            $Shell.SendKeys("{END}")
            $Shell.SendKeys("{HOME}")
        }
        $moves++

        if ($stopwatch.Elapsed.TotalSeconds -ge $nextSampleSeconds) {
            $Product.Refresh()
            if ($Product.HasExited) {
                throw "Product exited during the sustained caret-movement soak."
            }
            $windows = @(Get-VisibleProductWindows -Product $Product)
            $maxVisibleOverlays = [Math]::Max($maxVisibleOverlays, $windows.Count)
            if ($windows.Count -gt 1) {
                throw "More than one visible overlay appeared during the soak."
            }
            $samples += [ordered]@{
                elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
                handles = $Product.HandleCount
                privateMemoryBytes = $Product.PrivateMemorySize64
                visibleOverlays = $windows.Count
            }
            $nextSampleSeconds += 30.0
        }

        Start-Sleep -Milliseconds 40
    }

    $stopwatch.Stop()
    $Product.Refresh()
    $windowsAfter = @(Get-VisibleProductWindows -Product $Product)
    $maxVisibleOverlays = [Math]::Max($maxVisibleOverlays, $windowsAfter.Count)
    if ($windowsAfter.Count -ne 1) {
        throw "Visible overlay count after the sustained soak was $($windowsAfter.Count), expected 1."
    }

    $handleDelta = $Product.HandleCount - $handlesBefore
    $privateDelta = $Product.PrivateMemorySize64 - $privateBefore
    if ($handleDelta -gt 128) {
        throw "Handle growth is suspicious after the sustained soak: +$handleDelta."
    }
    if ($privateDelta -gt 134217728) {
        throw "Private-memory growth is suspicious after the sustained soak: +$privateDelta bytes."
    }

    return [ordered]@{
        requestedDurationSeconds = $DurationSeconds
        actualDurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        caretMoves = $moves
        sampleIntervalSeconds = 30
        samples = @($samples)
        maxVisibleOverlays = $maxVisibleOverlays
        finalVisibleOverlays = $windowsAfter.Count
        handleDelta = $handleDelta
        privateMemoryDeltaBytes = $privateDelta
    }
}

function Save-OverlayEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Overlay,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $width = $Overlay.Right - $Overlay.Left
    $height = $Overlay.Bottom - $Overlay.Top
    if ($width -le 0 -or $height -le 0) {
        throw "Overlay rectangle is invalid."
    }

    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen(
            $Overlay.Left,
            $Overlay.Top,
            0,
            0,
            $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)

        $dark = 0
        $bright = 0
        for ($y = 0; $y -lt $height; $y++) {
            for ($x = 0; $x -lt $width; $x++) {
                $pixel = $bitmap.GetPixel($x, $y)
                $luma = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                if ($luma -lt 60) {
                    $dark++
                }
                if ($luma -gt 180) {
                    $bright++
                }
            }
        }

        $pixels = $width * $height
        if ($dark -lt [Math]::Max(1, [Math]::Floor($pixels * 0.25))) {
            throw "Overlay screenshot did not contain enough dark background pixels."
        }
        if ($bright -lt 3) {
            throw "Overlay screenshot did not contain visible bright glyph pixels."
        }

        return [ordered]@{
            width = $width
            height = $height
            darkPixels = $dark
            brightPixels = $bright
            totalPixels = $pixels
        }
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$ExecutablePath = (Resolve-Path $ExecutablePath).Path
$artifactsDir = Join-Path (Get-Location) "artifacts"
New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
$evidencePath = Join-Path $artifactsDir "runtime-quality.json"
$screenshotPath = Join-Path $artifactsDir "runtime-quality-overlay.png"

$settingsPath = Join-Path $env:LOCALAPPDATA "WindowsImeCaretIndicator\settings.json"
$settingsBackup = Join-Path $env:TEMP ("wici-settings-" + [Guid]::NewGuid().ToString("N") + ".json")
$hadSettings = Test-Path $settingsPath
if ($hadSettings) {
    Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup -Force
}

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$hadRunValue = $false
$originalRunValue = $null
try {
    $originalRunValue = Get-ItemPropertyValue -Path $runKey -Name "WindowsImeCaretIndicator" -ErrorAction Stop
    $hadRunValue = $true
}
catch {
}

$hostProcess = $null
$product = $null
$secondary = $null
$shell = $null
$results = [ordered]@{}

try {
    Write-TestSettings -StartWithWindows $true -Paused $false -Path $settingsPath

    $hostProcess = Start-Process -FilePath $ExecutablePath -ArgumentList "--test-host" -PassThru
    Wait-MainWindow -Process $hostProcess

    $shell = New-Object -ComObject WScript.Shell
    $edit = Focus-TestHost -HostProcess $hostProcess -Shell $shell
    $baselineInput = Invoke-InputContinuityProbe `
        -HostProcess $hostProcess `
        -EditHandle $edit `
        -Shell $shell `
        -Text "inputpass"

    $product = Start-Process -FilePath $ExecutablePath -PassThru
    $overlay = Wait-VisibleOverlay -Product $product

    $startupValue = Wait-RunRegistration -RunKey $runKey -ExpectedPresent $true -ExpectedPath $ExecutablePath

    $requiredStyle = [int64](0x00000008 -bor 0x00000020 -bor 0x00000080 -bor 0x00080000 -bor 0x08000000)
    if (($overlay.ExStyle -band $requiredStyle) -ne $requiredStyle) {
        throw ("Overlay is missing required extended styles. actual=0x{0:X}, required=0x{1:X}" -f $overlay.ExStyle, $requiredStyle)
    }

    $probe = Get-Probe
    if ($probe.activeCaret -ne $true) {
        throw "Released product probe did not see the active native caret."
    }
    if ($probe.ime.mode -ne "English") {
        throw "Test host expected English mode but probe reported '$($probe.ime.mode)'."
    }

    $caretRect = [System.Drawing.Rectangle]::new(
        [int]$probe.caret.x,
        [int]$probe.caret.y,
        [int]$probe.caret.width,
        [int]$probe.caret.height)
    $overlayRect = [System.Drawing.Rectangle]::FromLTRB(
        [int]$overlay.Left,
        [int]$overlay.Top,
        [int]$overlay.Right,
        [int]$overlay.Bottom)
    if ($overlayRect.IntersectsWith($caretRect)) {
        throw "Overlay overlaps the actual text caret."
    }

    $focusBefore = [WiciRuntimeNative]::GetFocusedWindowForForeground()
    $foregroundBefore = [WiciRuntimeNative]::GetForegroundWindow()
    if ($foregroundBefore -ne $hostProcess.MainWindowHandle -or $focusBefore -ne $edit) {
        throw "Overlay presentation changed foreground or keyboard focus."
    }

    $productInput = Invoke-InputContinuityProbe `
        -HostProcess $hostProcess `
        -EditHandle $edit `
        -Shell $shell `
        -Text "inputpass"

    foreach ($counterName in @(
            "queueKeyDown",
            "queueKeyUp",
            "queueChar",
            "translatedKeyDown",
            "dispatchedKeyDown",
            "dispatchedKeyUp",
            "dispatchedChar")) {
        if ($productInput.counters[$counterName] -ne
            $baselineInput.counters[$counterName]) {
            throw "Input message count '$counterName' changed with the product running: baseline=$($baselineInput.counters[$counterName]), product=$($productInput.counters[$counterName])."
        }
    }

    $overlay = Wait-VisibleOverlay -Product $product
    $visual = Save-OverlayEvidence -Overlay $overlay -Path $screenshotPath

    $responsiveness = Measure-OverlayResponseLatency -Product $product -Shell $shell -SampleCount 20

    $focusNonText = [WiciRuntimeNative]::SendMessageW(
        $hostProcess.MainWindowHandle,
        0x8007,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    if ($focusNonText -eq [IntPtr]::Zero) {
        throw "Test host could not focus its actual non-text BUTTON control."
    }
    Start-Sleep -Milliseconds 100
    $nonTextFocus = [WiciRuntimeNative]::GetFocusedWindowForForeground()
    if ($nonTextFocus -eq [IntPtr]::Zero -or $nonTextFocus -eq $edit) {
        throw "Non-text BUTTON focus was not independently observed."
    }
    Wait-NoVisibleOverlay -Product $product

    $edit = Focus-TestHost -HostProcess $hostProcess -Shell $shell
    $null = Wait-VisibleOverlay -Product $product

    $shell.SendKeys("{HOME}")
    Start-Sleep -Milliseconds 250
    $beforeClickProbe = Get-Probe
    $beforeClickOverlay = Wait-VisibleOverlay -Product $product
    $editRect = [WiciRuntimeNative]::GetRect($edit)

    $intersectionLeft = [Math]::Max($beforeClickOverlay.Left, $editRect.Left)
    $intersectionTop = [Math]::Max($beforeClickOverlay.Top, $editRect.Top)
    $intersectionRight = [Math]::Min($beforeClickOverlay.Right, $editRect.Right)
    $intersectionBottom = [Math]::Min($beforeClickOverlay.Bottom, $editRect.Bottom)
    $clickThrough = "STYLE_AND_FOCUS_ONLY"

    if ($intersectionRight -gt $intersectionLeft -and $intersectionBottom -gt $intersectionTop) {
        $clickX = $intersectionRight - 1
        $clickY = [Math]::Floor(($intersectionTop + $intersectionBottom) / 2)
        [WiciRuntimeNative]::Click($clickX, $clickY)
        Start-Sleep -Milliseconds 250

        $afterClickProbe = Get-Probe
        $foregroundAfterClick = [WiciRuntimeNative]::GetForegroundWindow()
        $focusAfterClick = [WiciRuntimeNative]::GetFocusedWindowForForeground()
        if ($foregroundAfterClick -ne $hostProcess.MainWindowHandle -or $focusAfterClick -ne $edit) {
            throw "Click at the overlay changed target foreground/focus."
        }
        if ($afterClickProbe.activeCaret -ne $true) {
            throw "Caret disappeared after clicking the overlay area."
        }
        if ($clickX -gt ([int]$beforeClickProbe.caret.x + 4) -and
            [int]$afterClickProbe.caret.x -le [int]$beforeClickProbe.caret.x) {
            throw "Click at the overlay area did not reach the underlying edit control."
        }
        $clickThrough = "ACTUAL_CLICK_PASSED"
    }

    $secondary = Start-Process -FilePath $ExecutablePath -PassThru
    if (-not $secondary.WaitForExit(5000)) {
        throw "Second normal launch did not exit under the single-instance mutex."
    }
    if ($secondary.ExitCode -ne 0) {
        throw "Second normal launch exited with code $($secondary.ExitCode)."
    }
    $product.Refresh()
    if ($product.HasExited) {
        throw "Primary product instance exited during the single-instance test."
    }

    $product.Refresh()
    $handlesBefore = $product.HandleCount
    $privateBefore = $product.PrivateMemorySize64

    for ($i = 0; $i -lt 160; $i++) {
        if (($i % 2) -eq 0) {
            $shell.SendKeys("{LEFT}")
        }
        else {
            $shell.SendKeys("{RIGHT}")
        }
        if (($i % 20) -eq 0) {
            $shell.SendKeys("{END}")
            $shell.SendKeys("{HOME}")
        }
        Start-Sleep -Milliseconds 12
    }

    Start-Sleep -Milliseconds 500
    $product.Refresh()
    $handlesAfterStress = $product.HandleCount
    $privateAfterStress = $product.PrivateMemorySize64
    $handleDelta = $handlesAfterStress - $handlesBefore
    $privateDelta = $privateAfterStress - $privateBefore

    if ($handleDelta -gt 128) {
        throw "Handle growth is suspicious after repeated caret movement: +$handleDelta."
    }
    if ($privateDelta -gt 134217728) {
        throw "Private-memory growth is suspicious after repeated caret movement: +$privateDelta bytes."
    }

    $cpuBeforeIdle = $product.TotalProcessorTime.TotalSeconds
    Start-Sleep -Seconds 3
    $product.Refresh()
    $idleCpuSeconds = $product.TotalProcessorTime.TotalSeconds - $cpuBeforeIdle
    if ($idleCpuSeconds -gt 1.5) {
        throw "Idle CPU consumption was too high: $idleCpuSeconds CPU seconds over 3 wall seconds."
    }

    $windowsAfterStress = @(Get-VisibleProductWindows -Product $product)
    if ($windowsAfterStress.Count -ne 1) {
        throw "Visible overlay count after stress was $($windowsAfterStress.Count), expected 1."
    }

    $edit = Focus-TestHost -HostProcess $hostProcess -Shell $shell
    $soak = Invoke-CaretSoak -Product $product -Shell $shell -DurationSeconds 180

    $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $targetX = $work.Right - 730
    $targetY = $work.Bottom - 170
    if (-not [WiciRuntimeNative]::MoveNoActivate(
            $hostProcess.MainWindowHandle,
            $targetX,
            $targetY)) {
        throw "Unable to move the runtime host near the screen edge."
    }
    [void]$shell.AppActivate($hostProcess.Id)
    [void][WiciRuntimeNative]::SendMessageW(
        $hostProcess.MainWindowHandle,
        0x8006,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    $shell.SendKeys("^a")
    $shell.SendKeys("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    $shell.SendKeys("{END}")
    Start-Sleep -Milliseconds 300

    $edgeOverlay = Wait-VisibleOverlay -Product $product
    if ($edgeOverlay.Left -lt $work.Left -or
        $edgeOverlay.Top -lt $work.Top -or
        $edgeOverlay.Right -gt $work.Right -or
        $edgeOverlay.Bottom -gt $work.Bottom) {
        throw "Overlay escaped the primary monitor working area near an edge."
    }

    $results.releaseBinary = [ordered]@{
        path = $ExecutablePath
        sha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $results.overlay = [ordered]@{
        exStyle = ("0x{0:X}" -f $overlay.ExStyle)
        rect = [ordered]@{
            left = $overlay.Left
            top = $overlay.Top
            right = $overlay.Right
            bottom = $overlay.Bottom
        }
        source = $probe.caret.source
        mode = $probe.ime.mode
        visual = $visual
        screenshot = "artifacts/runtime-quality-overlay.png"
        clickThrough = $clickThrough
        noCaretOverlap = $true
        singleVisibleOverlayAfterStress = $true
    }
    $results.input = [ordered]@{
        foregroundPreserved = $true
        keyboardFocusPreserved = $true
        baseline = $baselineInput
        productRunning = $productInput
        messageCountsMatchedBaseline = $true
        singleInstance = $true
        nonTextControlHidden = $true
        nonTextFocusedHandle = $nonTextFocus.ToInt64()
    }
    $results.responsiveness = $responsiveness
    $results.stability = [ordered]@{
        stressIterations = 160
        handleDelta = $handleDelta
        privateMemoryDeltaBytes = $privateDelta
        idleCpuSecondsOver3Seconds = [Math]::Round($idleCpuSeconds, 4)
        sustainedSoak = $soak
    }
    $results.edgePlacement = [ordered]@{
        workingArea = [ordered]@{
            left = $work.Left
            top = $work.Top
            right = $work.Right
            bottom = $work.Bottom
        }
        overlay = [ordered]@{
            left = $edgeOverlay.Left
            top = $edgeOverlay.Top
            right = $edgeOverlay.Right
            bottom = $edgeOverlay.Bottom
        }
        contained = $true
    }
    $results.startupInitial = [ordered]@{
        registered = $true
        value = $startupValue
    }

    Stop-TrackedProcess -Process $product
    $product = $null

    Write-TestSettings -StartWithWindows $false -Paused $false -Path $settingsPath
    $edit = Focus-TestHost -HostProcess $hostProcess -Shell $shell
    $product = Start-Process -FilePath $ExecutablePath -PassThru
    $null = Wait-VisibleOverlay -Product $product
    $null = Wait-RunRegistration -RunKey $runKey -ExpectedPresent $false
    $results.startupDisabledPersisted = $true

    Stop-TrackedProcess -Process $product
    $product = $null

    Write-TestSettings -StartWithWindows $true -Paused $true -Path $settingsPath
    $edit = Focus-TestHost -HostProcess $hostProcess -Shell $shell
    $product = Start-Process -FilePath $ExecutablePath -PassThru
    $null = Wait-RunRegistration -RunKey $runKey -ExpectedPresent $true -ExpectedPath $ExecutablePath
    Assert-NoVisibleOverlay -Product $product
    $results.pausedPersisted = $true

    Stop-TrackedProcess -Process $product
    $product = $null

    Write-TestSettings -StartWithWindows $true -Paused $false -Path $settingsPath
    $edit = Focus-TestHost -HostProcess $hostProcess -Shell $shell
    $product = Start-Process -FilePath $ExecutablePath -PassThru
    $null = Wait-RunRegistration -RunKey $runKey -ExpectedPresent $true -ExpectedPath $ExecutablePath
    $null = Wait-VisibleOverlay -Product $product
    $results.resumePersisted = $true

    $trayPause = Invoke-TrayMenuAction -Product $product -Shell $shell -Action "FirstEnabled"
    $null = Wait-SettingsState -Path $settingsPath -StartWithWindows $true -Paused $true
    Wait-NoVisibleOverlay -Product $product

    $trayResume = Invoke-TrayMenuAction -Product $product -Shell $shell -Action "FirstEnabled"
    $null = Wait-SettingsState -Path $settingsPath -StartWithWindows $true -Paused $false
    $edit = Focus-TestHost -HostProcess $hostProcess -Shell $shell
    $null = Wait-VisibleOverlay -Product $product

    $trayStartupOff = Invoke-TrayMenuAction -Product $product -Shell $shell -Action "Startup"
    $null = Wait-SettingsState -Path $settingsPath -StartWithWindows $false -Paused $false
    $null = Wait-RunRegistration -RunKey $runKey -ExpectedPresent $false

    $trayStartupOn = Invoke-TrayMenuAction -Product $product -Shell $shell -Action "Startup"
    $null = Wait-SettingsState -Path $settingsPath -StartWithWindows $true -Paused $false
    $null = Wait-RunRegistration -RunKey $runKey -ExpectedPresent $true -ExpectedPath $ExecutablePath

    $trayExit = Invoke-TrayMenuAction -Product $product -Shell $shell -Action "Exit"
    if (-not $product.WaitForExit(5000)) {
        throw "Product did not exit after invoking the actual tray Exit menu item."
    }
    $results.trayLifecycle = [ordered]@{
        pause = $trayPause
        resume = $trayResume
        startupOff = $trayStartupOff
        startupOn = $trayStartupOn
        exit = $trayExit
        settingsAndRunRegistrationVerified = $true
        processExited = $true
    }
    $product = $null

    $displayItems = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $displayItems += [ordered]@{
            deviceName = $screen.DeviceName
            primary = $screen.Primary
            bounds = [ordered]@{
                x = $screen.Bounds.X
                y = $screen.Bounds.Y
                width = $screen.Bounds.Width
                height = $screen.Bounds.Height
            }
            workingArea = [ordered]@{
                x = $screen.WorkingArea.X
                y = $screen.WorkingArea.Y
                width = $screen.WorkingArea.Width
                height = $screen.WorkingArea.Height
            }
        }
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $results.environment = [ordered]@{
        userInteractive = [Environment]::UserInteractive
        isAdministrator = $isAdmin
        hostDpi = [WiciRuntimeNative]::GetDpiForWindow($hostProcess.MainWindowHandle)
        displays = $displayItems
        integrityGroups = ((& whoami /groups 2>&1) -join [Environment]::NewLine)
    }

    $pretty = $results | ConvertTo-Json -Depth 12
    $compact = $results | ConvertTo-Json -Depth 12 -Compress
    Set-Content -Path $evidencePath -Value $pretty -Encoding UTF8
    Write-Host "WICI_RUNTIME_QUALITY=$compact"
}
finally {
    Stop-TrackedProcess -Process $secondary
    Stop-TrackedProcess -Process $product
    Stop-TrackedProcess -Process $hostProcess

    if ($null -ne $shell) {
        try {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        catch {
        }
    }

    if ($hadSettings) {
        New-Item -ItemType Directory -Path (Split-Path $settingsPath -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $settingsBackup -Destination $settingsPath -Force
    }
    else {
        Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue
        $settingsDir = Split-Path $settingsPath -Parent
        if ((Test-Path $settingsDir) -and
            -not (Get-ChildItem -LiteralPath $settingsDir -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $settingsDir -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $settingsBackup -Force -ErrorAction SilentlyContinue

    if ($hadRunValue) {
        New-Item -Path $runKey -Force | Out-Null
        Set-ItemProperty -Path $runKey -Name "WindowsImeCaretIndicator" -Value $originalRunValue
    }
    else {
        Remove-ItemProperty -Path $runKey -Name "WindowsImeCaretIndicator" -ErrorAction SilentlyContinue
    }
}
