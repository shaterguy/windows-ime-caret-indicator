param(
    [Parameter(Mandatory = $true)]
    [string]$LegacyInstallerPath,
    [Parameter(Mandatory = $true)]
    [string]$CandidateInstallerPath
)

$ErrorActionPreference = "Stop"

$legacyInstaller = (Resolve-Path $LegacyInstallerPath).Path
$candidateInstaller = (Resolve-Path $CandidateInstallerPath).Path
$testUser = "WiciMig" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$testPassword = "W1ci!" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$publicDocuments = Join-Path $env:PUBLIC "Documents"
$testRoot = Join-Path $publicDocuments ("WiciFormalUpdate-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$publicLegacyInstaller = Join-Path $testRoot "WindowsImeCaretIndicator-Setup-0.1.0.exe"
Copy-Item -LiteralPath $legacyInstaller -Destination $publicLegacyInstaller -Force

$securePassword = ConvertTo-SecureString $testPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential(
    "$env:COMPUTERNAME\$testUser",
    $securePassword)

function Invoke-TestUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string]$Arguments = "",
        [int]$ExpectedExitCode = 0
    )

    $start = @{
        FilePath = $FilePath
        Credential = $credential
        LoadUserProfile = $true
        WorkingDirectory = $testRoot
        Wait = $true
        PassThru = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $start.ArgumentList = $Arguments
    }

    $process = Start-Process @start
    if ($process.ExitCode -ne $ExpectedExitCode) {
        throw "Test-user process '$FilePath' returned $($process.ExitCode); expected $ExpectedExitCode."
    }
}

$workerPath = Join-Path $testRoot "migration-worker.ps1"
@'
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Seed", "PreMigration", "Migrated")]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$CandidatePath
)

$ErrorActionPreference = "Stop"
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$legacyDirectory = Join-Path $local "Programs\Windows IME Caret Indicator"
$legacyExe = Join-Path $legacyDirectory "WindowsImeCaretIndicator.exe"
$settingsDirectory = Join-Path $local "WindowsImeCaretIndicator"
$legacySettings = Join-Path $settingsDirectory "settings.json"
$currentSettings = Join-Path $settingsDirectory "state-v2.json"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$legacyRunName = "WindowsImeCaretIndicator"
$currentRunName = "WindowsImeCaretIndicator.ProgramFiles"
$legacyUninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{77D81AE7-1E91-56DB-B694-8E60C764A76D}_is1"
$identityKey = "HKCU:\Software\SHatergUY\Windows IME Caret Indicator"

function Read-RunValue([string]$Name) {
    try {
        return (Get-ItemProperty -LiteralPath $runKey -Name $Name -ErrorAction Stop).$Name
    }
    catch {
        return $null
    }
}

$expectedLegacyRun = '"' + $legacyExe + '"'
$expectedCurrentRun = '"' + $CandidatePath + '"'

if ($Mode -eq "Seed") {
    if (-not (Test-Path -LiteralPath $legacyExe)) {
        throw "Formal v0.1.0 executable is missing."
    }
    if ((Read-RunValue $legacyRunName) -ne $expectedLegacyRun) {
        throw "Formal v0.1.0 Run registration is not the expected product path."
    }
    if (-not (Test-Path -LiteralPath $legacyUninstallKey)) {
        throw "Formal v0.1.0 uninstall identity is missing."
    }

    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    @{ StartWithWindows = $true; Paused = $true } |
        ConvertTo-Json |
        Set-Content -LiteralPath $legacySettings -Encoding UTF8
    exit 0
}

if ($Mode -eq "PreMigration") {
    if ((Read-RunValue $legacyRunName) -ne $expectedLegacyRun) {
        throw "Elevated candidate setup changed another user's legacy Run state."
    }
    if ($null -ne (Read-RunValue $currentRunName)) {
        throw "Elevated candidate setup created another user's current Run state."
    }
    if (Test-Path -LiteralPath $currentSettings) {
        throw "Elevated candidate setup created another user's current settings."
    }
    if (-not (Test-Path -LiteralPath $legacyUninstallKey)) {
        throw "Elevated candidate setup removed another user's legacy uninstall state."
    }
    exit 0
}

if ($null -ne (Read-RunValue $legacyRunName)) {
    throw "Legacy Run registration remains after migration."
}
if ((Read-RunValue $currentRunName) -ne $expectedCurrentRun) {
    throw "Current Run registration does not point to Program Files."
}
if (-not (Test-Path -LiteralPath $currentSettings)) {
    throw "Migrated current settings are missing."
}
$settings = Get-Content -LiteralPath $currentSettings -Raw | ConvertFrom-Json
if ($settings.StartWithWindows -ne $true -or $settings.Paused -ne $true) {
    throw "Migrated settings did not preserve v0.1.0 intent."
}
if (Test-Path -LiteralPath $legacyUninstallKey) {
    throw "Legacy uninstall registration remains after migration."
}
if (Test-Path -LiteralPath $legacyExe) {
    throw "Legacy executable remains after migration."
}
if (Test-Path -LiteralPath $legacySettings) {
    throw "Legacy settings remain after migration."
}

$generation = (Get-ItemProperty -LiteralPath $identityKey -Name Generation -ErrorAction Stop).Generation
$identityPath = (Get-ItemProperty -LiteralPath $identityKey -Name ExecutablePath -ErrorAction Stop).ExecutablePath
if ($generation -ne "programfiles-v2") {
    throw "Current install identity generation is invalid."
}
if ([IO.Path]::GetFullPath($identityPath) -ne [IO.Path]::GetFullPath($CandidatePath)) {
    throw "Current install identity path is invalid."
}
'@ | Set-Content -LiteralPath $workerPath -Encoding UTF8

$windowsPowerShell = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$candidateInstallDirectory = Join-Path $env:ProgramFiles "Windows IME Caret Indicator"
$candidateExe = Join-Path $candidateInstallDirectory "WindowsImeCaretIndicator.exe"

$userCreated = $false
$candidateInstalled = $false

try {
    & net.exe user $testUser $testPassword /add /expires:never /passwordchg:no | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create isolated standard test user."
    }
    $userCreated = $true

    Invoke-TestUser -FilePath $env:ComSpec -Arguments "/c exit 0"

    $account = [System.Security.Principal.NTAccount]::new($env:COMPUTERNAME, $testUser)
    $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    $profilePath = [Environment]::ExpandEnvironmentVariables(
        (Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath).ProfileImagePath)
    $legacyInstallDirectory = Join-Path $profilePath "AppData\Local\Programs\Windows IME Caret Indicator"

    Invoke-TestUser -FilePath $publicLegacyInstaller -Arguments "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"

    $seedArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $workerPath + '" -Mode Seed -CandidatePath "' + $candidateExe + '"'
    Invoke-TestUser -FilePath $windowsPowerShell -Arguments $seedArgs

    $legacyUninstallerCopy = Join-Path $testRoot "legacy-uninstaller"
    New-Item -ItemType Directory -Path $legacyUninstallerCopy -Force | Out-Null
    Get-ChildItem -LiteralPath $legacyInstallDirectory -Filter "unins*" |
        Copy-Item -Destination $legacyUninstallerCopy -Force

    $candidateProcess = Start-Process -FilePath $candidateInstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
    if ($candidateProcess.ExitCode -ne 0) {
        throw "Candidate installer failed with exit code $($candidateProcess.ExitCode)."
    }
    $candidateInstalled = $true

    if (-not (Test-Path -LiteralPath $candidateExe)) {
        throw "Candidate Program Files executable is missing."
    }

    $preArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $workerPath + '" -Mode PreMigration -CandidatePath "' + $candidateExe + '"'
    Invoke-TestUser -FilePath $windowsPowerShell -Arguments $preArgs

    Invoke-TestUser -FilePath $candidateExe -Arguments "--verify-protected-install"

    $untrustedDirectory = Join-Path $profilePath "AppData\Local\WiciUntrusted"
    New-Item -ItemType Directory -Path $untrustedDirectory -Force | Out-Null
    $untrustedExe = Join-Path $untrustedDirectory "WindowsImeCaretIndicator.exe"
    Copy-Item -LiteralPath $candidateExe -Destination $untrustedExe -Force
    Invoke-TestUser -FilePath $untrustedExe -Arguments "--verify-protected-install" -ExpectedExitCode 4

    Invoke-TestUser -FilePath $candidateExe -Arguments "--migrate-v010"

    $migratedArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $workerPath + '" -Mode Migrated -CandidatePath "' + $candidateExe + '"'
    Invoke-TestUser -FilePath $windowsPowerShell -Arguments $migratedArgs

    $oldUninstaller = Get-ChildItem -LiteralPath $legacyUninstallerCopy -Filter "unins*.exe" | Select-Object -First 1
    if (-not $oldUninstaller) {
        throw "Copied formal v0.1.0 uninstaller is missing."
    }
    Invoke-TestUser -FilePath $oldUninstaller.FullName -Arguments "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"

    Invoke-TestUser -FilePath $windowsPowerShell -Arguments $migratedArgs
    Write-Host "Formal v0.1.0 -> v0.1.1 migration passed."
}
finally {
    if ($candidateInstalled -and (Test-Path -LiteralPath $candidateInstallDirectory)) {
        $candidateUninstaller = Get-ChildItem -LiteralPath $candidateInstallDirectory -Filter "unins*.exe" | Select-Object -First 1
        if ($candidateUninstaller) {
            $cleanup = Start-Process -FilePath $candidateUninstaller.FullName -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
            if ($cleanup.ExitCode -ne 0) {
                Write-Warning "Candidate cleanup returned $($cleanup.ExitCode)."
            }
        }
    }

    if ($userCreated) {
        & net.exe user $testUser /delete | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Unable to remove isolated migration test user."
        }
    }

    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
