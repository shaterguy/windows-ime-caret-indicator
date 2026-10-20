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
Add-Type -AssemblyName System.Drawing
if (-not ('WiciChromeProbe.Foreground' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace WiciChromeProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct WindowRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KeyInput { public ushort Vk, Scan; public uint Flags, Time; public IntPtr Extra; }
    [StructLayout(LayoutKind.Explicit, Size=40)]
    public struct Input { [FieldOffset(0)] public uint Type; [FieldOffset(8)] public KeyInput Key; }
    public static class Foreground {
        [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, Input[] input, int size);
        private static Input Key(ushort key, bool up) => new Input { Type=1, Key=new KeyInput { Vk=key, Flags=up ? 2u : 0u } };
        public static void Press(ushort key, bool control) {
            Input[] inputs = control ? new[] { Key(0x11,false), Key(key,false), Key(key,true), Key(0x11,true) }
                                     : new[] { Key(key,false), Key(key,true) };
            if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length) {
                var release = new[] { Key(0x11,true), Key(key,true) };
                SendInput((uint)release.Length, release, Marshal.SizeOf<Input>());
                throw new InvalidOperationException("Native synthetic keyboard input was incomplete.");
            }
        }
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out WindowRect rect);
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
$focusProcess = $null
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
    Wait-Ui 500
}

function Send-ChromeKey([uint16]$Key, [bool]$Control = $false) {
    $foregroundId = [WiciChromeProbe.Foreground]::ProcessId()
    if (-not (@(Get-OwnedChrome | Where-Object { $_.ProcessId -eq $foregroundId }).Count)) {
        throw 'Chrome lost foreground focus; refusing native keys.'
    }
    [WiciChromeProbe.Foreground]::Press($Key, $Control)
    Wait-Ui 500
}

function Invoke-CaretProbe([string]$Name, [string]$Action) {
    # Capture only the verified synthetic target window, never unrelated desktop.
    $window = [WiciChromeProbe.Foreground]::GetForegroundWindow()
    [uint32]$owner = 0
    $null = [WiciChromeProbe.Foreground]::GetWindowThreadProcessId($window, [ref]$owner)
    $ownedTarget = $focusProcess -and $owner -eq $focusProcess.Id
    if (-not $ownedTarget -and -not (@(Get-OwnedChrome | Where-Object { $_.ProcessId -eq $owner }).Count)) {
        throw 'Screenshot target is not an owned synthetic window.'
    }
    $rect = [WiciChromeProbe.WindowRect]::new()
    if (-not [WiciChromeProbe.Foreground]::GetWindowRect($window, [ref]$rect)) { throw 'Target bounds unavailable.' }
    $screen = [Drawing.Rectangle]::FromLTRB($rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
    $screen = [Drawing.Rectangle]::Intersect($screen, [Windows.Forms.SystemInformation]::VirtualScreen)
    $bitmap = [Drawing.Bitmap]::new($screen.Width, $screen.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($screen.Location, [Drawing.Point]::Empty, $screen.Size)
        $bitmap.Save((Join-Path $OutputDirectory "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
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
        # This process owns the temporary focus-loss Form. Pump its UI thread
        # while the child probes it so UIA requests can be served normally.
        $probeTimer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $probe.HasExited -and $probeTimer.Elapsed.TotalSeconds -lt $ProbeTimeoutSeconds) {
            Wait-Ui 25
        }
        if (-not $probe.HasExited) {
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
    Write-Host ($record | ConvertTo-Json -Depth 12 -Compress)
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
    Send-ChromeKey 0x4C $true
    Send-ChromeKeys 'wici-caret-probe.invalid'
    Invoke-CaretProbe 'ordinary-omnibox-caret' 'Ctrl+L, then synthetic text without Enter.'

    Send-ChromeKey 0x25
    Invoke-CaretProbe 'left-move-without-typing' 'One Left arrow after the ordinary caret case; text unchanged.'

    Send-ChromeKey 0x41 $true
    Invoke-CaretProbe 'omnibox-selection' 'Ctrl+A selects all synthetic omnibox text.'

    Send-ChromeKey 0x08
    Invoke-CaretProbe 'empty-omnibox' 'Backspace clears the selected synthetic text.'

    Send-ChromeKeys 'wici-caret-probe.invalid'
    $targetScript = Join-Path $PSScriptRoot 'focus-loss-host.ps1'
    $focusProcess = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @(
        '-NoLogo', '-NoProfile', '-Sta', '-File', "`"$targetScript`"") -WindowStyle Hidden -PassThru
    $targetTimer = [Diagnostics.Stopwatch]::StartNew()
    while ($targetTimer.Elapsed.TotalSeconds -lt 10) {
        $focusProcess.Refresh()
        if ($focusProcess.HasExited) { throw 'Standalone focus target exited unexpectedly.' }
        if ($focusProcess.MainWindowHandle -ne 0 -and $shell.AppActivate($focusProcess.Id)) {
            Wait-Ui 300
            if ([WiciChromeProbe.Foreground]::ProcessId() -eq $focusProcess.Id) { break }
        }
        Wait-Ui 100
    }
    if ([WiciChromeProbe.Foreground]::ProcessId() -ne $focusProcess.Id) {
        throw 'Standalone non-text target did not acquire focus.'
    }
    Invoke-CaretProbe 'focus-loss-button' 'Chrome loses focus to a temporary WinForms button, not another text field.'
}
catch {
    $runError = $_.Exception.Message
}
finally {
    if ($focusProcess) {
        try {
            if (-not $focusProcess.HasExited) { $focusProcess.Kill($true); $null = $focusProcess.WaitForExit(3000) }
        } catch { Write-Warning "Could not stop owned focus target: $($_.Exception.Message)" }
        finally { $focusProcess.Dispose() }
    }
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
$byCase = @{}
foreach ($result in $results) { $byCase[$result.case] = $result }
foreach ($name in @('ordinary-omnibox-caret', 'left-move-without-typing', 'omnibox-selection', 'empty-omnibox')) {
    if ($byCase[$name].status -ne 'caret') { throw "Required real caret/selection was not found: $name" }
}
if ($byCase['focus-loss-button'].status -ne 'no-caret') { throw 'Non-text focus retained an unwanted caret.' }
if ($byCase['omnibox-selection'].probe.caret.source -ne 'UIA.TextPattern.SelectionBlockEdge') {
    throw 'Selection case did not expose a real noncollapsed text range.'
}
if ($byCase['left-move-without-typing'].probe.caret.x -ge $byCase['ordinary-omnibox-caret'].probe.caret.x) {
    throw 'Left arrow did not move the actual caret left.'
}
if ($byCase['empty-omnibox'].probe.caret.x -ge $byCase['ordinary-omnibox-caret'].probe.caret.x) {
    throw 'Cleared omnibox did not expose an earlier empty-field caret.'
}
Write-Host "Chrome caret/selection state gates passed; screenshots still require inspection. Results: $OutputDirectory"
