param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class WiciForeground
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

function Invoke-DriverJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [object]$Body = $null
    )

    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri
    }

    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Method $Method -Uri $Uri -ContentType "application/json" -Body $json
}

function Wait-Driver {
    param([int]$Port)

    for ($i = 0; $i -lt 30; $i++) {
        try {
            $null = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$Port/status"
            return
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }

    throw "WebDriver on port $Port did not become ready."
}

function Focus-BrowserWindow {
    param([string]$ProcessName)

    for ($i = 0; $i -lt 30; $i++) {
        $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1

        if ($process) {
            if ([WiciForeground]::SetForegroundWindow($process.MainWindowHandle)) {
                return
            }
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Unable to foreground browser process '$ProcessName'."
}

function Test-BrowserCaret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$DriverPath,
        [Parameter(Mandatory = $true)]
        [string]$ProcessName,
        [Parameter(Mandatory = $true)]
        [string]$OptionsKey,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    if (-not (Test-Path $DriverPath)) {
        throw "$Name WebDriver was not found at '$DriverPath'."
    }

    $driver = Start-Process -FilePath $DriverPath -ArgumentList "--port=$Port", "--silent" -PassThru -WindowStyle Hidden
    $sessionId = $null

    try {
        Wait-Driver -Port $Port

        $alwaysMatch = @{
            browserName = $Name
            $OptionsKey = @{
                args = @(
                    "--force-renderer-accessibility",
                    "--no-first-run",
                    "--disable-search-engine-choice-screen",
                    "--disable-features=TranslateUI",
                    "--window-size=1000,700"
                )
            }
        }

        $session = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$Port/session" -Body @{
            capabilities = @{
                alwaysMatch = $alwaysMatch
            }
        }

        $sessionId = $session.value.sessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            throw "$Name WebDriver did not return a session id."
        }

        $html = @"
<!doctype html>
<meta charset="utf-8">
<title>WICI browser caret test</title>
<style>
body { font: 24px Segoe UI; padding: 80px; }
textarea { width: 720px; height: 220px; font: 24px Consolas; }
</style>
<textarea id="probe">abc</textarea>
"@
        $url = "data:text/html;charset=utf-8," + [Uri]::EscapeDataString($html)

        $null = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$Port/session/$sessionId/url" -Body @{
            url = $url
        }

        Focus-BrowserWindow -ProcessName $ProcessName

        $focus = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$Port/session/$sessionId/execute/sync" -Body @{
            script = @"
const el = document.getElementById('probe');
el.focus();
el.setSelectionRange(2, 2);
return document.activeElement === el;
"@
            args = @()
        }

        if ($focus.value -ne $true) {
            throw "$Name did not focus the test textarea."
        }

        Start-Sleep -Milliseconds 300

        $output = & $ExecutablePath --probe-once
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "$Name caret probe exited with code $exitCode. Output: $output"
        }

        $jsonLine = $output | Select-Object -Last 1
        $probe = $jsonLine | ConvertFrom-Json

        if ($probe.activeCaret -ne $true) {
            throw "$Name caret probe did not report an active caret."
        }

        if ($probe.caret.source -ne "UIA3.TextPattern2.GetCaretRange") {
            throw "$Name caret source was '$($probe.caret.source)' instead of UIA3.TextPattern2.GetCaretRange."
        }

        if ($probe.caret.height -le 0) {
            throw "$Name caret height is invalid: $($probe.caret.height)."
        }

        if ($probe.ime.mode -eq "Unknown") {
            throw "$Name IME mode could not be resolved."
        }

        Write-Host "$Name browser caret probe passed: source=$($probe.caret.source), mode=$($probe.ime.mode), rect=$($probe.caret.x),$($probe.caret.y),$($probe.caret.width),$($probe.caret.height)"
    }
    finally {
        if ($sessionId) {
            try {
                $null = Invoke-DriverJson -Method Delete -Uri "http://127.0.0.1:$Port/session/$sessionId"
            }
            catch {
            }
        }

        if ($driver -and -not $driver.HasExited) {
            Stop-Process -Id $driver.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Test-BrowserCaret -Name "chrome" -DriverPath (Join-Path $env:CHROMEWEBDRIVER "chromedriver.exe") -ProcessName "chrome" -OptionsKey "goog:chromeOptions" -Port 9515
Test-BrowserCaret -Name "MicrosoftEdge" -DriverPath (Join-Path $env:EDGEWEBDRIVER "msedgedriver.exe") -ProcessName "msedge" -OptionsKey "ms:edgeOptions" -Port 9516
