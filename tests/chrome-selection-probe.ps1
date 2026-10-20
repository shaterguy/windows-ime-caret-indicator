#requires -Version 7.0
param(
    [Parameter(Mandatory = $true)]
    [Alias('ExePath')]
    [string]$ExecutablePath,
    [string]$ChromePath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts/chrome-selection-probe'),
    [ValidateRange(1, 60)]
    [int]$ProbeTimeoutSeconds = 10,
    [ValidateRange(1, 60)]
    [int]$StartupTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This diagnostic requires Windows and an interactive desktop.' }
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
if (-not $ChromePath) {
    $ChromePath = @(
        (Join-Path $env:ProgramFiles 'Google/Chrome/Application/chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google/Chrome/Application/chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google/Chrome/Application/chrome.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $ChromePath) { throw 'Installed Google Chrome was not found. Supply -ChromePath.' }
$ChromePath = (Resolve-Path -LiteralPath $ChromePath).Path
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

Add-Type -AssemblyName System.Windows.Forms
if (-not ('WiciChromeProbe.Foreground' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace WiciChromeProbe {
    public static class Foreground {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        public static uint ProcessId() {
            uint process;
            GetWindowThreadProcessId(GetForegroundWindow(), out process);
            return process;
        }
    }
}
'@
}

$profile = Join-Path ([IO.Path]::GetTempPath()) ('wici-chrome-probe-' + [guid]::NewGuid().ToString('N'))
$results = [Collections.Generic.List[object]]::new()
$shell = New-Object -ComObject WScript.Shell
$focusForm = $null
$launchProcess = $null
$runError = $null

function Get-OwnedChrome {
    # Never select a user's existing Chrome just because it has a window.
    Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -OperationTimeoutSec 5 |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.Contains('--user-data-dir=') -and
            $_.CommandLine.Contains($profile) -and
            $_.CommandLine -notmatch '(?:^|\s)--type='
        }
}

function Wait-Ui([int]$Milliseconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $Milliseconds) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
}

function Focus-OwnedChrome {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
        foreach ($owned in @(Get-OwnedChrome)) {
            $window = Get-Process -Id $owned.ProcessId -ErrorAction SilentlyContinue
            if ($window -and $window.MainWindowHandle -ne 0 -and $shell.AppActivate([int]$owned.ProcessId)) {
                Wait-Ui 100
                if ([WiciChromeProbe.Foreground]::ProcessId() -eq $owned.ProcessId) { return }
            }
        }
        Wait-Ui 100
    }
    throw 'Could not foreground the isolated Chrome window; no keystrokes were sent to another app.'
}

function Send-ChromeKeys([string]$Keys) {
    $foregroundId = [WiciChromeProbe.Foreground]::ProcessId()
    if (-not (@(Get-OwnedChrome | Where-Object { $_.ProcessId -eq $foregroundId }).Count)) {
        throw 'Chrome lost foreground focus; refusing to send keystrokes to another app.'
    }
    $shell.SendKeys($Keys)
    Wait-Ui 200
}

function Invoke-CaretProbe([string]$Name, [string]$Action) {
    $foregroundId = [WiciChromeProbe.Foreground]::ProcessId()
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $ExecutablePath
    $start.ArgumentList.Add('--probe-once')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $probe = [Diagnostics.Process]::new()
    $probe.StartInfo = $start
    $started = $false
    $timedOut = $false
    $exitCode = $null
    $stdout = ''
    $stderr = ''
    try {
        $started = $probe.Start()
        if (-not $started) { throw 'Caret probe failed to start.' }
        $outTask = $probe.StandardOutput.ReadToEndAsync()
        $errTask = $probe.StandardError.ReadToEndAsync()
        if (-not $probe.WaitForExit($ProbeTimeoutSeconds * 1000)) {
            $timedOut = $true
            $probe.Kill($true)
            $null = $probe.WaitForExit(2000)
        }
        if ($probe.HasExited) { $exitCode = $probe.ExitCode }
        if ($outTask.Wait(2000)) { $stdout = $outTask.Result }
        if ($errTask.Wait(2000)) { $stderr = $errTask.Result }
    }
    finally {
        if ($started -and -not $probe.HasExited) {
            try { $probe.Kill($true) } catch { }
        }
        $probe.Dispose()
    }

    $payload = $null
    $parseError = $null
    $json = $stdout -split '\r?\n' | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    try {
        if (-not $json) { throw 'Probe did not emit a JSON object.' }
        $payload = $json | ConvertFrom-Json
    }
    catch { $parseError = $_.Exception.Message }

    # Exit 3 is the documented "no active caret" result, not a test failure.
    $status = if ($timedOut) { 'timeout' }
        elseif ($exitCode -notin @(0, 3)) { 'probe-error' }
        elseif ($parseError) { 'invalid-json' }
        elseif ($exitCode -eq 3 -and $payload.activeCaret -eq $false) { 'no-caret' }
        elseif ($exitCode -eq 0 -and $payload.activeCaret -eq $true) { 'caret' }
        else { 'inconsistent-result' }
    $record = [ordered]@{
        case = $Name
        action = $Action
        status = $status
        exitCode = $exitCode
        timedOut = $timedOut
        foregroundProcessId = $foregroundId
        capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
        probe = $payload
        parseError = $parseError
        stdout = $stdout
        stderr = $stderr
    }
    $results.Add($record)
    $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$Name.json") -Encoding utf8
    Write-Host "$Name : $status (exit $exitCode)"
}

try {
    New-Item -ItemType Directory -Path $profile | Out-Null
    $chromeStart = [Diagnostics.ProcessStartInfo]::new()
    $chromeStart.FileName = $ChromePath
    $chromeStart.UseShellExecute = $false
    # No forced accessibility, automation, remote debugging, or security flags.
    foreach ($argument in @("--user-data-dir=$profile", '--no-first-run', '--no-default-browser-check', '--new-window', 'about:blank')) {
        $chromeStart.ArgumentList.Add($argument)
    }
    $launchProcess = [Diagnostics.Process]::Start($chromeStart)
    Focus-OwnedChrome
    Send-ChromeKeys '^l'
    Send-ChromeKeys 'wici-caret-probe.invalid'
    Invoke-CaretProbe 'ordinary-omnibox-caret' 'Ctrl+L, then synthetic text without Enter.'

    Send-ChromeKeys '{LEFT}'
    Invoke-CaretProbe 'left-move-without-typing' 'One Left arrow after the ordinary caret case; text unchanged.'

    Send-ChromeKeys '^a'
    Invoke-CaretProbe 'omnibox-selection' 'Ctrl+A selects all synthetic omnibox text.'

    Send-ChromeKeys '{BACKSPACE}'
    Invoke-CaretProbe 'empty-omnibox' 'Backspace clears the selected synthetic text.'

    Send-ChromeKeys 'wici-caret-probe.invalid'
    $focusForm = [Windows.Forms.Form]::new()
    $focusForm.Text = 'WICI temporary non-text focus target'
    $focusForm.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $button = [Windows.Forms.Button]::new()
    $button.Text = 'Non-text focus target'
    $button.Dock = [Windows.Forms.DockStyle]::Fill
    $focusForm.Controls.Add($button)
    $focusForm.Show()
    $focusForm.Activate()
    $null = $button.Focus()
    Wait-Ui 300
    if ([WiciChromeProbe.Foreground]::GetForegroundWindow() -ne $focusForm.Handle -or -not $button.Focused) {
        throw 'Temporary non-text button did not acquire focus.'
    }
    Invoke-CaretProbe 'focus-loss-button' 'Chrome loses focus to a temporary WinForms button, not another text field.'
}
catch {
    $runError = $_.Exception.Message
}
finally {
    if ($focusForm) { $focusForm.Close(); $focusForm.Dispose() }
    # Kill only the unique profile's browser root and its own descendants.
    $ownedProcesses = @()
    try { $ownedProcesses = @(Get-OwnedChrome) }
    catch { Write-Warning "Could not enumerate owned Chrome processes during cleanup: $($_.Exception.Message)" }
    foreach ($owned in $ownedProcesses) {
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$owned.ProcessId)
            $process.Kill($true)
            $null = $process.WaitForExit(3000)
            $process.Dispose()
        }
        catch { Write-Warning "Could not stop owned Chrome PID $($owned.ProcessId): $($_.Exception.Message)" }
    }
    if ($launchProcess) { $launchProcess.Dispose() }
    if (Test-Path -LiteralPath $profile) {
        try { Remove-Item -LiteralPath $profile -Recurse -Force }
        catch { Write-Warning "Temporary diagnostic profile remains at '$profile': $($_.Exception.Message)" }
    }
    $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    [ordered]@{
        diagnosticOnly = $true
        forcedAccessibility = $false
        chromePath = $ChromePath
        executablePath = $ExecutablePath
        runError = $runError
        cases = $results.ToArray()
    } | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding utf8
}

if ($runError) { throw $runError }
if (@($results | Where-Object { $_.status -notin @('caret', 'no-caret') }).Count) {
    throw "Probe execution errors were recorded. See '$OutputDirectory/summary.json'."
}
Write-Host "Chrome selection diagnostic complete. 'no-caret' is an observation, not a failure. Results: $OutputDirectory"
