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
    $output = @(& $ExecutablePath --probe-once 2>&1)
    $exitCode = $LASTEXITCODE
    return Convert-ProbeResult -Output $output -ExitCode $exitCode
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

function Focus-NamedDescendantForRename {
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
        $root = [System.Windows.Automation.AutomationElement]::FromHandle(
            $Process.MainWindowHandle)
        if ($null -eq $root) {
            return [ordered]@{
                success = $false
                reason = "Explorer UI Automation root was unavailable."
            }
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
        $all = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)

        $target = $null
        foreach ($element in $all) {
            try {
                $elementName = $element.Current.Name
                if ($elementName -eq $Name -or
                    $elementName -eq $baseName -or
                    $elementName -like "$baseName*") {
                    $target = $element
                    break
                }
            }
            catch {
            }
        }

        $windowTitle = $Process.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($windowTitle) -or
            -not $Shell.AppActivate($windowTitle)) {
            return [ordered]@{
                success = $false
                reason = "Explorer test window could not be activated by its exact title."
                focused = (Get-FocusedControlSnapshot)
            }
        }
        Start-Sleep -Milliseconds 150

        if ([WiciTargetDiscoveryNative]::GetForegroundWindow() -ne
            $Process.MainWindowHandle) {
            return [ordered]@{
                success = $false
                reason = "Explorer test window did not become the foreground window."
                focused = (Get-FocusedControlSnapshot)
            }
        }

        if ($null -ne $target) {
            try {
                $selectionPattern = $null
                if ($target.TryGetCurrentPattern(
                        [System.Windows.Automation.SelectionItemPattern]::Pattern,
                        [ref]$selectionPattern)) {
                    ([System.Windows.Automation.SelectionItemPattern]$selectionPattern).Select()
                }

                $target.SetFocus()
                Start-Sleep -Milliseconds 200

                $preRenameFocus = Get-FocusedControlSnapshot
                if (-not $preRenameFocus.exists -or
                    -not $preRenameFocus.hasKeyboardFocus -or
                    $preRenameFocus.processId -ne $Process.Id -or
                    $preRenameFocus.controlType -eq "ControlType.Window") {
                    return [ordered]@{
                        success = $false
                        reason = "Explorer target item did not retain keyboard focus before F2."
                        focused = $preRenameFocus
                    }
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
        else {
            $itemsCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                "ItemsView")
            $itemsView = $root.FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                $itemsCondition)

            if ($null -eq $itemsView) {
                return [ordered]@{
                    success = $false
                    reason = "Neither target file nor Explorer ItemsView was found in UI Automation tree."
                    focused = (Get-FocusedControlSnapshot)
                }
            }

            try {
                $itemsView.SetFocus()
                Start-Sleep -Milliseconds 150
                $Shell.SendKeys("^a")
                Start-Sleep -Milliseconds 150
            }
            catch {
                return [ordered]@{
                    success = $false
                    reason = "Explorer ItemsView could not be focused for keyboard selection."
                    focused = (Get-FocusedControlSnapshot)
                }
            }
        }

        $Shell.SendKeys("{F2}")
        $focused = Wait-FocusedEdit -Attempts 40

        if (Test-EditableFocusSnapshot -Snapshot $focused) {
            return [ordered]@{
                success = $true
                focused = $focused
            }
        }

        return [ordered]@{
            success = $false
            reason = "F2 did not place keyboard focus in an Explorer rename edit."
            focused = $focused
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
        $focusResult = Focus-NamedDescendantForRename -Process $process -Name $fileName -Shell $shell

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
        vscode = (Find-Executable -Candidates @(
            (Join-Path $programFiles "Microsoft VS Code\Code.exe"),
            (Join-Path $localAppData "Programs\Microsoft VS Code\Code.exe")
        ))
        webView2Runtime = (Find-Executable -Candidates @(
            (Join-Path $programFilesX86 "Microsoft\EdgeWebView\Application\msedgewebview2.exe"),
            (Join-Path $programFiles "Microsoft\EdgeWebView\Application\msedgewebview2.exe")
        ))
    }
    probes = [ordered]@{
        notepad = (Test-Notepad)
        settingsSearch = (Test-SettingsSearch)
        explorerRename = (Test-ExplorerRename)
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
