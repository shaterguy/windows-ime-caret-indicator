param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

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
                status = "UNAVAILABLE"
                reason = "SystemSettings process with a main window was not available."
            }
        }

        $shell = Activate-Process -Process $process
        $shell.SendKeys("^f")
        Start-Sleep -Milliseconds 250
        $shell.SendKeys("display")
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

function Test-ExplorerRename {
    $shell = $null
    $folder = Join-Path $env:TEMP ("WiciExplorerProbe-" + [Guid]::NewGuid().ToString("N"))
    $file = Join-Path $folder "probe-file.txt"
    $process = $null

    try {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -Path $file -Value "probe" -Encoding UTF8

        $argument = '/select,"' + $file + '"'
        Start-Process -FilePath "explorer.exe" -ArgumentList $argument | Out-Null

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
                status = "UNAVAILABLE"
                reason = "Explorer test folder window was not discovered."
            }
        }

        $shell = Activate-Process -Process $process
        $shell.SendKeys("{F2}")
        Start-Sleep -Milliseconds 300

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
    throw "No built-in Windows target could be probed in this runner."
}
