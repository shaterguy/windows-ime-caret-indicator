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

    for ($i = 0; $i -lt 40; $i++) {
        try {
            $null = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$Port/status"
            return
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }

    throw "ChromeDriver did not become ready."
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

        if ($process.ExitCode -ne 0) {
            throw "Caret probe exited with code $($process.ExitCode): $($output -join ' | ')"
        }

        $jsonLine = $output | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace($jsonLine)) {
            throw "Caret probe did not emit JSON: $($output -join ' | ')"
        }

        return ($jsonLine | ConvertFrom-Json)
    }
    finally {
        $process.Dispose()
    }
}

function Focus-ChromeWindow {
    $shell = New-Object -ComObject WScript.Shell
    try {
        for ($i = 0; $i -lt 40; $i++) {
            $process = Get-Process -Name "chrome" -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } |
                Sort-Object StartTime -Descending |
                Select-Object -First 1
            if ($process -and $shell.AppActivate($process.Id)) {
                Start-Sleep -Milliseconds 200
                return
            }
            Start-Sleep -Milliseconds 100
        }
        throw "Unable to foreground the ChatGPT Chrome window."
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

New-Item -ItemType Directory -Path "artifacts" -Force | Out-Null
$evidencePath = "artifacts/chatgpt-caret.json"
$driverPath = Join-Path $env:CHROMEWEBDRIVER "chromedriver.exe"
$driver = $null
$sessionId = $null
$result = [ordered]@{
    timestampUtc = [DateTimeOffset]::UtcNow.ToString("O")
    target = "https://chatgpt.com/"
    status = "HARNESS_ERROR"
}
$exitCode = 0

try {
    if (-not (Test-Path $driverPath)) {
        throw "ChromeDriver was not found at '$driverPath'."
    }

    $port = 9517
    $driver = Start-Process -FilePath $driverPath -ArgumentList "--port=$port", "--silent" -PassThru -WindowStyle Hidden
    Wait-Driver -Port $port

    $session = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$port/session" -Body @{
        capabilities = @{
            alwaysMatch = @{
                browserName = "chrome"
                "goog:chromeOptions" = @{
                    args = @(
                        "--force-renderer-accessibility",
                        "--no-first-run",
                        "--disable-search-engine-choice-screen",
                        "--disable-features=TranslateUI",
                        "--window-size=1200,800"
                    )
                }
            }
        }
    }

    $sessionId = $session.value.sessionId
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw "ChromeDriver did not return a session id."
    }

    $null = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$port/session/$sessionId/url" -Body @{
        url = "https://chatgpt.com/"
    }

    $snapshot = $null
    for ($i = 0; $i -lt 50; $i++) {
        $response = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$port/session/$sessionId/execute/sync" -Body @{
            script = @'
const visibleEditable = [...document.querySelectorAll('textarea,[contenteditable="true"],[role="textbox"]')]
  .filter(el => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    const editable = el.isContentEditable || (el.tagName === 'TEXTAREA' && !el.readOnly && !el.disabled);
    return editable && r.width > 1 && r.height > 1 &&
      s.display !== 'none' && s.visibility !== 'hidden' &&
      el.getAttribute('aria-disabled') !== 'true';
  });

const describe = el => {
  const r = el.getBoundingClientRect();
  return {
    tag: el.tagName,
    id: el.id || '',
    role: el.getAttribute('role') || '',
    contentEditable: !!el.isContentEditable,
    ariaLabel: el.getAttribute('aria-label') || '',
    placeholder: el.getAttribute('placeholder') || '',
    dataTestId: el.getAttribute('data-testid') || '',
    rect: {x:r.x,y:r.y,width:r.width,height:r.height}
  };
};

const preferred = visibleEditable.find(el => el.id === 'prompt-textarea') ||
  visibleEditable.find(el => (el.getAttribute('data-testid') || '').toLowerCase().includes('prompt')) ||
  visibleEditable.find(el => el.isContentEditable) ||
  visibleEditable.find(el => el.tagName === 'TEXTAREA') ||
  null;

return {
  href: location.href,
  title: document.title,
  candidateCount: visibleEditable.length,
  candidates: visibleEditable.slice(0, 12).map(describe),
  selected: preferred ? describe(preferred) : null
};
'@
            args = @()
        }
        $snapshot = $response.value
        if ($snapshot -and $snapshot.selected) {
            break
        }
        Start-Sleep -Milliseconds 400
    }

    $result.page = $snapshot
    if (-not $snapshot -or -not $snapshot.selected) {
        $result.status = "TARGET_UNAVAILABLE"
        $result.reason = "No visible editable ChatGPT composer was available in this unauthenticated automated session; no product failure was inferred."
    }
    else {
        $focusResponse = Invoke-DriverJson -Method Post -Uri "http://127.0.0.1:$port/session/$sessionId/execute/sync" -Body @{
            script = @'
const all = [...document.querySelectorAll('textarea,[contenteditable="true"],[role="textbox"]')];
const visible = all.filter(el => {
  const r = el.getBoundingClientRect();
  const s = getComputedStyle(el);
  const editable = el.isContentEditable || (el.tagName === 'TEXTAREA' && !el.readOnly && !el.disabled);
  return editable && r.width > 1 && r.height > 1 &&
    s.display !== 'none' && s.visibility !== 'hidden' &&
    el.getAttribute('aria-disabled') !== 'true';
});
const el = visible.find(x => x.id === 'prompt-textarea') ||
  visible.find(x => (x.getAttribute('data-testid') || '').toLowerCase().includes('prompt')) ||
  visible.find(x => x.isContentEditable) ||
  visible.find(x => x.tagName === 'TEXTAREA') ||
  null;
if (!el) return {focused:false};
el.focus();
if (el.isContentEditable) {
  const range = document.createRange();
  range.selectNodeContents(el);
  range.collapse(false);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
} else if (typeof el.setSelectionRange === 'function') {
  const n = el.value.length;
  el.setSelectionRange(n, n);
}
return {focused:document.activeElement === el, id:el.id || '', tag:el.tagName};
'@
            args = @()
        }

        $result.focus = $focusResponse.value
        if (-not $focusResponse.value.focused) {
            $result.status = "HARNESS_FOCUS_UNAVAILABLE"
            $result.reason = "A visible editable composer existed but did not retain DOM focus."
        }
        else {
            Focus-ChromeWindow
            Start-Sleep -Milliseconds 250
            $probe = Invoke-CaretProbe
            $result.probe = $probe

            if ($probe.activeCaret -eq $true) {
                $result.status = "PROBED"
            }
            else {
                $result.status = "PRODUCT_CARET_GAP"
                $result.reason = "An actual visible ChatGPT composer was focused without typing or submitting content, but the released WICI probe did not report an active caret."
                $exitCode = 1
            }
        }
    }
}
catch {
    $result.status = "HARNESS_ERROR"
    $result.reason = $_.Exception.Message
}
finally {
    if ($sessionId) {
        try {
            $null = Invoke-DriverJson -Method Delete -Uri "http://127.0.0.1:9517/session/$sessionId"
        }
        catch {
        }
    }
    if ($driver -and -not $driver.HasExited) {
        Stop-Process -Id $driver.Id -Force -ErrorAction SilentlyContinue
    }

    $result | ConvertTo-Json -Depth 12 | Set-Content -Path $evidencePath -Encoding UTF8
    Write-Host ("WICI_CHATGPT_CARET=" + ($result | ConvertTo-Json -Depth 12 -Compress))
}

exit $exitCode
