param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"

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

    $shell = New-Object -ComObject WScript.Shell

    for ($i = 0; $i -lt 30; $i++) {
        $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1

        if ($process -and $shell.AppActivate($process.Id)) {
            return
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Unable to foreground browser process '$ProcessName'."
}

function Invoke-WiciProbe {
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

        if ($process.ExitCode -ne 0) {
            throw "Caret probe exited with code $($process.ExitCode). Output: $($output -join ' | ')"
        }

        $jsonLine = $output |
            Where-Object { $_ -match '^\s*\{' } |
            Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace($jsonLine)) {
            throw "Caret probe did not emit JSON. Output: $($output -join ' | ')"
        }

        return $jsonLine | ConvertFrom-Json
    }
    finally {
        $process.Dispose()
    }
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
body { font: 24px Segoe UI; padding: 60px; }
input, textarea, [contenteditable] { display: block; width: 720px; margin: 24px 0; font: 24px Consolas; }
textarea { height: 160px; }
[contenteditable] { min-height: 80px; border: 1px solid #888; padding: 4px; }
</style>
<input id="probe-input" value="abc">
<textarea id="probe-textarea">abc</textarea>
<div id="probe-contenteditable" contenteditable="true">abc</div>
"@
        $url = "data:text/html;charset=utf-8," + [Uri]::EscapeDataString($html)

        $null = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$Port/session/$sessionId/url" -Body @{
            url = $url
        }

        Focus-BrowserWindow -ProcessName $ProcessName

        foreach ($target in @(
            @{ Id = "probe-input"; Label = "input" },
            @{ Id = "probe-textarea"; Label = "textarea" },
            @{ Id = "probe-contenteditable"; Label = "contenteditable" }
        )) {
            $focus = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$Port/session/$sessionId/execute/sync" -Body @{
                script = @"
const el = document.getElementById(arguments[0]);
el.focus();
if (el.isContentEditable) {
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
} else {
    el.setSelectionRange(2, 2);
}
return document.activeElement === el;
"@
                args = @($target.Id)
            }

            if ($focus.value -ne $true) {
                throw "$Name did not focus the test $($target.Label)."
            }

            Start-Sleep -Milliseconds 300

            try {
                $probe = Invoke-WiciProbe
            }
            catch {
                throw "$Name $($target.Label) caret probe failed: $($_.Exception.Message)"
            }

            if ($probe.activeCaret -ne $true) {
                throw "$Name $($target.Label) caret probe did not report an active caret."
            }

            $allowedSources = @(
                "UIA3.TextPattern2.GetCaretRange",
                "UIA.TextPattern.Selection"
            )

            if ($allowedSources -notcontains $probe.caret.source) {
                throw "$Name $($target.Label) caret source '$($probe.caret.source)' did not use a UI Automation caret path."
            }

            if ($probe.caret.height -le 0) {
                throw "$Name $($target.Label) caret height is invalid: $($probe.caret.height)."
            }

            if ($probe.ime.mode -eq "Unknown") {
                throw "$Name $($target.Label) IME mode could not be resolved."
            }

            Write-Host "$Name $($target.Label) caret probe passed: source=$($probe.caret.source), mode=$($probe.ime.mode), rect=$($probe.caret.x),$($probe.caret.y),$($probe.caret.width),$($probe.caret.height)"
        }
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
