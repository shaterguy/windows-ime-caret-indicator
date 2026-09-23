param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeScriptPath,
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
$logDirectory = Split-Path -Parent $LogPath
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

try {
    & $RuntimeScriptPath -ExecutablePath $ExecutablePath *>&1 |
        Tee-Object -FilePath $LogPath
    exit 0
}
catch {
    $_ | Out-String |
        Tee-Object -FilePath $LogPath -Append |
        Write-Host
    exit 1
}
