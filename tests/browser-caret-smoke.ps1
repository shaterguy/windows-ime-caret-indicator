param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"

dotnet run --file "$PSScriptRoot/browser-caret-smoke.cs" -- $ExecutablePath
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
