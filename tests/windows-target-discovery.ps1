param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class WiciTargetDiscoveryNative
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(
        uint dwFlags,
        uint dx,
        uint dy,
        uint dwData,
        UIntPtr dwExtraInfo);

    public static bool ClickWindowCenter(IntPtr hwnd)
    {
        const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        const uint MOUSEEVENTF_LEFTUP = 0x0004;

        if (!GetWindowRect(hwnd, out var rect))
            return false;

        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0)
            return false;

        var x = rect.Left + (width / 2);
        var y = rect.Top + (height / 2);
        if (!SetCursorPos(x, y))
            return false;

        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
        return true;
    }
}
"@

function Convert-ProbeResult {
    param(
        [string[]]$Output,
        [int]$ExitCode
    )

    $jsonLine = $Output | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        return [ordered]@{
            exitCode = $ExitCode
            parseable = $false
            raw = ($Output -join [Environment]::NewLine)
        }
    }

    try {
        $payload = $jsonLine | ConvertFrom-Json
        return [ordered]@{
            exitCode = $ExitCode
            parseable = $true
            payload = $payload
        }
    }
    catch {
        return [ordered]@{
            exitCode = $ExitCode
            parseable = $false
            raw = ($Output -join [Environment]::NewLine)
            parseError = $_.Exception.Message
        }
    }
}

function Invoke-CaretProbe {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.ArgumentList.Add("--probe-once")
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Caret probe process did not start."
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $output = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $output += ($stdout -split "\r?\n")
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $output += ($stderr -split "\r?\n")
        }

        return Convert-ProbeResult -Output $output -ExitCode $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Wait-MainWindow {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [int]$Attempts = 50
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) {
                return $false
            }
            if ($Process.MainWindowHandle -ne 0) {
                return $true
            }
        }
        catch {
            return $false
        }
        Start-Sleep -Milliseconds 100
    }

    return $false
}

function Activate-Process {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [int]$Attempts = 30
    )

    $shell = New-Object -ComObject WScript.Shell
    try {
        for ($i = 0; $i -lt $Attempts; $i++) {
            try {
                $Process.Refresh()
                if (-not $Process.HasExited -and $shell.AppActivate($Process.Id)) {
                    Start-Sleep -Milliseconds 150
                    return $shell
                }
            }
            catch {
            }
            Start-Sleep -Milliseconds 100
        }
        throw "Unable to activate process $($Process.ProcessName) ($($Process.Id))."
    }
    catch {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        throw
    }
}

function Close-ProcessSafely {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }

    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            if ($Process.MainWindowHandle -ne 0) {
                [void]$Process.CloseMainWindow()
                if ($Process.WaitForExit(1500)) {
                    return
                }
            }
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Find-Executable {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}


function Get-FocusedControlSnapshot {
    try {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused) {
            return [ordered]@{
                exists = $false
                hasKeyboardFocus = $false
            }
        }

        $valuePatternAvailable = $false
        $valueIsReadOnly = $null
        try {
            $rawValuePattern = $null
            if ($focused.TryGetCurrentPattern(
                    [System.Windows.Automation.ValuePattern]::Pattern,
                    [ref]$rawValuePattern)) {
                $valuePatternAvailable = $true
                $valueIsReadOnly = ([System.Windows.Automation.ValuePattern]$rawValuePattern).Current.IsReadOnly
            }
        }
        catch {
        }

        return [ordered]@{
            exists = $true
            hasKeyboardFocus = [bool]$focused.Current.HasKeyboardFocus
            controlType = $focused.Current.ControlType.ProgrammaticName
            name = $focused.Current.Name
            automationId = $focused.Current.AutomationId
            nativeWindowHandle = $focused.Current.NativeWindowHandle
            processId = $focused.Current.ProcessId
            valuePatternAvailable = $valuePatternAvailable
            valueIsReadOnly = $valueIsReadOnly
        }
    }
    catch {
        return [ordered]@{
            exists = $false
            hasKeyboardFocus = $false
            error = $_.Exception.Message
        }
    }
}

function Test-EditableFocusSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    return $Snapshot.exists -and
        $Snapshot.hasKeyboardFocus -and
        (
            $Snapshot.controlType -eq "ControlType.Edit" -or
            (
                $Snapshot.valuePatternAvailable -eq $true -and
                $Snapshot.valueIsReadOnly -eq $false
            )
        )
}

function Wait-FocusedEdit {
    param([int]$Attempts = 30)

    for ($i = 0; $i -lt $Attempts; $i++) {
        $snapshot = Get-FocusedControlSnapshot
        if (Test-EditableFocusSnapshot -Snapshot $snapshot) {
            return $snapshot
        }
        Start-Sleep -Milliseconds 100
    }

    return Get-FocusedControlSnapshot
}

function Focus-FirstEditableDescendant {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    try {
        $Process.Refresh()
        if ($Process.MainWindowHandle -eq 0) {
            return [ordered]@{
                success = $false
                reason = "Process has no main window."
            }
        }

        $root = [System.Windows.Automation.AutomationElement]::FromHandle(
            $Process.MainWindowHandle)
        if ($null -eq $root) {
            return [ordered]@{
                success = $false
                reason = "UI Automation root was unavailable."
            }
        }

        $editCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit)
        $focusableCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::IsKeyboardFocusableProperty,
            $true)
        $condition = [System.Windows.Automation.AndCondition]::new(
            @($editCondition, $focusableCondition))

        $edits = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition)

        foreach ($edit in $edits) {
            try {
                $edit.SetFocus()
                $focused = Wait-FocusedEdit
                if ($focused.exists -and
                    $focused.hasKeyboardFocus -and
                    $focused.controlType -eq "ControlType.Edit") {
                    return [ordered]@{
                        success = $true
                        focused = $focused
                    }
                }
            }
            catch {
            }
        }

        return [ordered]@{
            success = $false
            reason = "No focusable edit descendant accepted keyboard focus."
            focused = (Get-FocusedControlSnapshot)
        }
    }
    catch {
        return [ordered]@{
            success = $false
            reason = $_.Exception.Message
            focused = (Get-FocusedControlSnapshot)
        }
    }
}

function Start-ExplorerRenameAttempt {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [object]$Shell
    )

    try {
        $Process.Refresh()
        $windowTitle = $Process.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($windowTitle) -or
            -not $Shell.AppActivate($windowTitle)) {
            return [ordered]@{
                success = $false
                reason = "Explorer test window could not be activated by its exact title."
                focused = (Get-FocusedControlSnapshot)
            }
        }
        Start-Sleep -Milliseconds 200

        if ([WiciTargetDiscoveryNative]::GetForegroundWindow() -ne
            $Process.MainWindowHandle) {
            return [ordered]@{
                success = $false
                reason = "Explorer test window did not become the foreground window."
                focused = (Get-FocusedControlSnapshot)
            }
        }

        $preRenameFocus = Get-FocusedControlSnapshot

        # The temporary directory contains exactly one test file. Selection and
        # actual edit state are not inferred from UIA control type. Downstream
        # code proves rename mode by committing a unique name and observing the
        # filesystem change.
        $Shell.SendKeys("^a")
        Start-Sleep -Milliseconds 150
        $selectedFocus = Get-FocusedControlSnapshot
        $Shell.SendKeys("{F2}")
        Start-Sleep -Milliseconds 300
        $postF2Focus = Get-FocusedControlSnapshot

        if ($postF2Focus.controlType -eq "ControlType.ListItem") {
            $Shell.SendKeys("{F2}")
            Start-Sleep -Milliseconds 300
            $postF2Focus = Get-FocusedControlSnapshot
        }

        return [ordered]@{
            success = $true
            targetName = $Name
            preRenameFocus = $preRenameFocus
            selectedFocus = $selectedFocus
            focused = $postF2Focus
            patternBasedEditable = (Test-EditableFocusSnapshot -Snapshot $postF2Focus)
            evidence = "F2 dispatched in an exact foreground Explorer window containing one temporary file; actual rename mode is proven only by keyboard edit plus filesystem commit."
        }
    }
    catch {
        return [ordered]@{
            success = $false
            reason = $_.Exception.Message
            focused = (Get-FocusedControlSnapshot)
        }
    }
}

function Classify-FocusedProbe {
    param(
        [Parameter(Mandatory = $true)]
        [object]$FocusResult
    )

    if (-not $FocusResult.success) {
        return [ordered]@{
            status = "HARNESS_FOCUS_UNAVAILABLE"
            focus = $FocusResult
        }
    }

    $probe = Invoke-CaretProbe
    $active = $probe.parseable -eq $true -and
        $probe.payload.activeCaret -eq $true

    return [ordered]@{
        status = $(if ($active) { "PROBED" } else { "PRODUCT_CARET_GAP" })
        focus = $FocusResult
        probe = $probe
    }
}

function Test-Notepad {
    $process = $null
    $shell = $null
    try {
        $process = Start-Process -FilePath "notepad.exe" -PassThru
        if (-not (Wait-MainWindow -Process $process)) {
            throw "Notepad main window did not appear."
        }
        $shell = Activate-Process -Process $process
        $shell.SendKeys("wici")
        Start-Sleep -Milliseconds 250
        return [ordered]@{
            status = "PROBED"
            process = $process.ProcessName
            probe = (Invoke-CaretProbe)
        }
    }
    catch {
        return [ordered]@{
            status = "ERROR"
            error = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        Close-ProcessSafely -Process $process
    }
}

function Test-SettingsSearch {
    $process = $null
    $shell = $null
    try {
        Start-Process -FilePath "explorer.exe" -ArgumentList "ms-settings:"
        for ($i = 0; $i -lt 80; $i++) {
            $process = Get-Process -Name "SystemSettings" -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } |
                Select-Object -First 1
            if ($process) {
                break
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $process) {
            return [ordered]@{
                status = "TARGET_UNAVAILABLE"
                reason = "SystemSettings process with a main window was not available."
            }
        }

        $shell = Activate-Process -Process $process
        $focusResult = Focus-FirstEditableDescendant -Process $process
        if ($focusResult.success) {
            $shell.SendKeys("display")
            Start-Sleep -Milliseconds 200
        }

        $classified = Classify-FocusedProbe -FocusResult $focusResult
        return [ordered]@{
            status = $classified.status
            process = $process.ProcessName
            focus = $classified.focus
            probe = $classified.probe
        }
    }
    catch {
        return [ordered]@{
            status = "HARNESS_ERROR"
            error = $_.Exception.Message
            focused = (Get-FocusedControlSnapshot)
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        Close-ProcessSafely -Process $process
    }
}

function Test-ExplorerRename {
    $shell = $null
    $folder = Join-Path $env:TEMP ("WiciExplorerProbe-" + [Guid]::NewGuid().ToString("N"))
    $fileName = "probe-file.txt"
    $file = Join-Path $folder $fileName
    $process = $null

    try {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -Path $file -Value "probe" -Encoding UTF8

        Start-Process -FilePath "explorer.exe" -ArgumentList $folder | Out-Null
        $folderName = Split-Path $folder -Leaf

        for ($i = 0; $i -lt 80; $i++) {
            $process = Get-Process -Name "explorer" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.MainWindowHandle -ne 0 -and
                    $_.MainWindowTitle -like "*$folderName*"
                } |
                Select-Object -First 1
            if ($process) {
                break
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $process) {
            return [ordered]@{
                status = "TARGET_UNAVAILABLE"
                reason = "Explorer test folder window was not discovered."
            }
        }

        $shell = Activate-Process -Process $process
        $renameAttempt = Start-ExplorerRenameAttempt -Process $process -Name $fileName -Shell $shell
        if (-not $renameAttempt.success) {
            return [ordered]@{
                status = "HARNESS_FOCUS_UNAVAILABLE"
                process = $process.ProcessName
                renameAttempt = $renameAttempt
            }
        }

        $renameToken = "wici-rename-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
        # The prior independently successful run proved this exact sequence
        # reliably enters/edits the Explorer rename surface. The filesystem
        # rename below remains the authoritative proof that editing was real.
        $shell.SendKeys("^a")
        Start-Sleep -Milliseconds 100
        $shell.SendKeys($renameToken)
        Start-Sleep -Milliseconds 250

        $focusDuringRename = Get-FocusedControlSnapshot
        $probe = Invoke-CaretProbe

        $shell.SendKeys("{ENTER}")

        $renamed = $null
        for ($i = 0; $i -lt 30; $i++) {
            $renamed = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -ne $fileName -and
                    ($_.Name -like "$renameToken*" -or $_.BaseName -eq $renameToken)
                } |
                Select-Object -First 1
            if ($renamed) {
                break
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $renamed) {
            return [ordered]@{
                status = "HARNESS_RENAME_UNPROVEN"
                process = $process.ProcessName
                renameAttempt = $renameAttempt
                focusDuringRename = $focusDuringRename
                probe = $probe
                reason = "Keyboard edit was not committed as a filesystem rename, so the probe is not classified as product evidence."
            }
        }

        $active = $probe.parseable -eq $true -and
            $probe.payload.activeCaret -eq $true

        return [ordered]@{
            status = $(if ($active) { "PROBED" } else { "PRODUCT_CARET_GAP" })
            process = $process.ProcessName
            renameConfirmed = $true
            originalName = $fileName
            committedName = $renamed.Name
            renameAttempt = $renameAttempt
            focusDuringRename = $focusDuringRename
            probe = $probe
        }
    }
    catch {
        return [ordered]@{
            status = "HARNESS_ERROR"
            error = $_.Exception.Message
            focused = (Get-FocusedControlSnapshot)
        }
    }
    finally {
        if ($null -ne $shell) {
            try {
                $shell.SendKeys("{ESC}")
            }
            catch {
            }
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        Close-ProcessSafely -Process $process
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-WebView2RuntimeRegistration {
    $clientId = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    if ([Environment]::Is64BitOperatingSystem) {
        $paths = @(
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$clientId",
            "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$clientId"
        )
    }
    else {
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$clientId",
            "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$clientId"
        )
    }

    $registrations = @()
    foreach ($path in $paths) {
        try {
            $pv = (Get-ItemProperty -LiteralPath $path -Name "pv" -ErrorAction Stop).pv
            if (-not [string]::IsNullOrWhiteSpace($pv) -and $pv -ne "0.0.0.0") {
                $registrations += [ordered]@{
                    registryPath = $path
                    version = [string]$pv
                }
            }
        }
        catch {
        }
    }

    return [ordered]@{
        installed = $registrations.Count -gt 0
        registrations = @($registrations)
        detection = "Microsoft-documented EdgeUpdate Clients pv registry contract"
    }
}

function Test-VscodeEditor {
    param([string]$VscodePath)

    if ([string]::IsNullOrWhiteSpace($VscodePath) -or -not (Test-Path $VscodePath)) {
        return [ordered]@{
            status = "TARGET_UNAVAILABLE"
            reason = "VS Code executable was not available."
        }
    }

    $folder = Join-Path $env:TEMP ("WiciVscodeProbe-" + [Guid]::NewGuid().ToString("N"))
    $file = Join-Path $folder "vscode-probe.txt"
    $userData = Join-Path $folder "user-data"
    $extensions = Join-Path $folder "extensions"
    $process = $null
    $shell = $null
    $startedAt = [DateTime]::UtcNow
    $marker = "wicielectronproof"

    try {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath $file -Value "initial" -Encoding UTF8

        $fileArg = "${file}:1:1"
        Start-Process -FilePath $VscodePath -ArgumentList @(
            "--new-window",
            "--disable-extensions",
            "--disable-workspace-trust",
            "--skip-welcome",
            "--skip-release-notes",
            "--user-data-dir=$userData",
            "--extensions-dir=$extensions",
            "--goto",
            $fileArg
        ) | Out-Null

        for ($i = 0; $i -lt 120; $i++) {
            $process = Get-Process -Name "Code" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.MainWindowHandle -ne 0 -and
                    $_.MainWindowTitle -like "*vscode-probe.txt*"
                } |
                Sort-Object StartTime -Descending |
                Select-Object -First 1
            if ($process) {
                break
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $process) {
            return [ordered]@{
                status = "HARNESS_FOCUS_UNAVAILABLE"
                reason = "VS Code did not expose an interactive main window."
            }
        }

        $shell = Activate-Process -Process $process
        Start-Sleep -Milliseconds 700

        # Ctrl+G is a global VS Code command. Entering line 1 and confirming
        # returns keyboard focus to the active text editor without relying on
        # screen coordinates or accessibility-role guessing.
        $shell.SendKeys("^g")
        Start-Sleep -Milliseconds 200
        $shell.SendKeys("1")
        $shell.SendKeys("{ENTER}")
        Start-Sleep -Milliseconds 300

        $shell.SendKeys("^a")
        Start-Sleep -Milliseconds 100
        $shell.SendKeys($marker)
        Start-Sleep -Milliseconds 300

        $focusDuringEdit = Get-FocusedControlSnapshot
        $probe = Invoke-CaretProbe

        $shell.SendKeys("^s")
        $saved = $false
        for ($i = 0; $i -lt 40; $i++) {
            try {
                $content = (Get-Content -LiteralPath $file -Raw -ErrorAction Stop).Trim()
                if ($content -eq $marker) {
                    $saved = $true
                    break
                }
            }
            catch {
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $saved) {
            return [ordered]@{
                status = "HARNESS_EDIT_UNPROVEN"
                process = $process.ProcessName
                focusDuringEdit = $focusDuringEdit
                probe = $probe
                reason = "Keyboard editing could not be independently proven by saving the marker to the opened file."
            }
        }

        $active = $probe.parseable -eq $true -and
            $probe.payload.activeCaret -eq $true

        return [ordered]@{
            status = $(if ($active) { "PROBED" } else { "PRODUCT_CARET_GAP" })
            process = $process.ProcessName
            version = (& $VscodePath --version 2>$null | Select-Object -First 1)
            editConfirmed = $true
            focusDuringEdit = $focusDuringEdit
            probe = $probe
        }
    }
    catch {
        return [ordered]@{
            status = "HARNESS_ERROR"
            error = $_.Exception.Message
            focused = (Get-FocusedControlSnapshot)
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }

        Get-Process -Name "Code" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.StartTime.ToUniversalTime() -ge $startedAt.AddSeconds(-2)) {
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-WebView2Host {
    param([string]$HostPath)

    if ([string]::IsNullOrWhiteSpace($HostPath) -or -not (Test-Path $HostPath)) {
        return [ordered]@{
            status = "TARGET_UNAVAILABLE"
            reason = "WebView2 test host executable was not built."
        }
    }

    $process = $null
    $shell = $null
    $marker = "wiciwebviewproof"

    try {
        $process = Start-Process -FilePath $HostPath -PassThru
        if (-not (Wait-MainWindow -Process $process -Attempts 100)) {
            return [ordered]@{
                status = "HARNESS_FOCUS_UNAVAILABLE"
                reason = "WebView2 test host did not expose a main window."
            }
        }

        $ready = $false
        for ($i = 0; $i -lt 120; $i++) {
            $process.Refresh()
            if ($process.HasExited) {
                break
            }
            if ($process.MainWindowTitle -like "*Ready*") {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $ready) {
            return [ordered]@{
                status = "TARGET_UNAVAILABLE"
                reason = "WebView2 runtime host did not reach DOM-ready state."
                title = $process.MainWindowTitle
            }
        }

        $shell = Activate-Process -Process $process
        Start-Sleep -Milliseconds 250
        $shell.SendKeys($marker)

        $editConfirmed = $false
        for ($i = 0; $i -lt 40; $i++) {
            $process.Refresh()
            if ($process.MainWindowTitle -like "*Input=$marker*") {
                $editConfirmed = $true
                break
            }
            Start-Sleep -Milliseconds 100
        }

        $focusDuringEdit = Get-FocusedControlSnapshot
        $probe = Invoke-CaretProbe

        if (-not $editConfirmed) {
            return [ordered]@{
                status = "HARNESS_EDIT_UNPROVEN"
                process = $process.ProcessName
                title = $process.MainWindowTitle
                focusDuringEdit = $focusDuringEdit
                probe = $probe
                reason = "WebView2 DOM input did not echo the keyboard marker through host web messaging."
            }
        }

        $active = $probe.parseable -eq $true -and
            $probe.payload.activeCaret -eq $true

        return [ordered]@{
            status = $(if ($active) { "PROBED" } else { "PRODUCT_CARET_GAP" })
            process = $process.ProcessName
            editConfirmed = $true
            focusDuringEdit = $focusDuringEdit
            probe = $probe
        }
    }
    catch {
        return [ordered]@{
            status = "HARNESS_ERROR"
            error = $_.Exception.Message
            focused = (Get-FocusedControlSnapshot)
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        Close-ProcessSafely -Process $process
    }
}

function Get-DisplayInventory {
    $items = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $dpi = [WiciTargetDiscoveryNative]::GetDpiForSystem()
        $items += [ordered]@{
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
            systemDpi = $dpi
            scalePercent = [Math]::Round(($dpi / 96.0) * 100, 2)
        }
    }
    return $items
}

$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$officeRoots = @(
    (Join-Path $programFiles "Microsoft Office\root\Office16"),
    (Join-Path $programFilesX86 "Microsoft Office\root\Office16"),
    (Join-Path $programFiles "Microsoft Office\Office16"),
    (Join-Path $programFilesX86 "Microsoft Office\Office16")
)

$wordCandidates = @()
$excelCandidates = @()
$outlookCandidates = @()
foreach ($root in $officeRoots) {
    $wordCandidates += (Join-Path $root "WINWORD.EXE")
    $excelCandidates += (Join-Path $root "EXCEL.EXE")
    $outlookCandidates += (Join-Path $root "OUTLOOK.EXE")
}

$os = Get-CimInstance Win32_OperatingSystem
$webView2Registration = Get-WebView2RuntimeRegistration
$vscodePath = Find-Executable -Candidates @(
    (Join-Path $programFiles "Microsoft VS Code\Code.exe"),
    (Join-Path $localAppData "Programs\Microsoft VS Code\Code.exe")
)
$webView2HostPath = Get-ChildItem "tests\WebView2CaretHost\bin\Release" -Recurse -Filter "WebView2CaretHost.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 |
    ForEach-Object { $_.FullName }

$results = [ordered]@{
    timestampUtc = [DateTimeOffset]::UtcNow.ToString("O")
    os = [ordered]@{
        caption = $os.Caption
        version = $os.Version
        buildNumber = $os.BuildNumber
        architecture = $os.OSArchitecture
    }
    session = [ordered]@{
        name = $env:SESSIONNAME
        userInteractive = [Environment]::UserInteractive
        user = [Environment]::UserName
    }
    displays = @(Get-DisplayInventory)
    installedTargets = [ordered]@{
        word = (Find-Executable -Candidates $wordCandidates)
        excel = (Find-Executable -Candidates $excelCandidates)
        outlook = (Find-Executable -Candidates $outlookCandidates)
        vscode = $vscodePath
        webView2Runtime = $webView2Registration
        webView2Host = $webView2HostPath
    }
    probes = [ordered]@{
        notepad = (Test-Notepad)
        settingsSearch = (Test-SettingsSearch)
        explorerRename = (Test-ExplorerRename)
        vscodeElectron = (Test-VscodeEditor -VscodePath $vscodePath)
        webView2 = (Test-WebView2Host -HostPath $webView2HostPath)
    }
}

New-Item -ItemType Directory -Path "artifacts" -Force | Out-Null
$pretty = $results | ConvertTo-Json -Depth 12
$compact = $results | ConvertTo-Json -Depth 12 -Compress
Set-Content -Path "artifacts/runtime-target-discovery.json" -Value $pretty -Encoding UTF8
Write-Host "WICI_RUNTIME_TARGET_DISCOVERY=$compact"

$probed = @($results.probes.GetEnumerator() | Where-Object { $_.Value.status -eq "PROBED" })
$active = @($probed | Where-Object { $_.Value.probe.parseable -eq $true -and $_.Value.probe.payload.activeCaret -eq $true })
Write-Host "Probed built-in targets: $($probed.Count); active-caret probes: $($active.Count)."

if ($probed.Count -eq 0) {
    Write-Host "No built-in Windows target produced an active-caret PASS; discovery evidence remains diagnostic."
}

exit 0
