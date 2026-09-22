param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateInstaller
)

$ErrorActionPreference = "Stop"

$LegacyInstallerUrl =
    "https://github.com/shaterguy/windows-ime-caret-indicator/releases/download/v0.1.0/WindowsImeCaretIndicator-Setup-0.1.0.exe"
$LegacyInstallerSha256 =
    "16ada7eea952664eecde78079c10da94421e65da6ff126e2d5c90f73d7d92f54"
$LegacyExecutableSha256 =
    "35981ffa5c433dad472f91c5ee7752429cdcdf17f097a291608bdd103955d202"

Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class WiciRestrictedLaunchResult
{
    public int ProcessId { get; set; }
    public int IntegrityRid { get; set; }
    public int ExitCode { get; set; }
}

public static class WiciRestrictedLauncher
{
    private const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint TOKEN_ADJUST_DEFAULT = 0x0080;
    private const uint DISABLE_MAX_PRIVILEGE = 0x00000001;
    private const uint LUA_TOKEN = 0x00000004;
    private const int TokenIntegrityLevel = 25;
    private const uint SE_GROUP_INTEGRITY = 0x00000020;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;

    [StructLayout(LayoutKind.Sequential)]
    private struct SID_AND_ATTRIBUTES
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_MANDATORY_LABEL
    {
        public SID_AND_ATTRIBUTES Label;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(
        IntPtr handle,
        uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(
        IntPtr process,
        out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(
        IntPtr process,
        uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateRestrictedToken(
        IntPtr existingTokenHandle,
        uint flags,
        uint disableSidCount,
        [In] SID_AND_ATTRIBUTES[] sidsToDisable,
        uint deletePrivilegeCount,
        IntPtr privilegesToDelete,
        uint restrictedSidCount,
        IntPtr sidsToRestrict,
        out IntPtr newTokenHandle);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSidToSidW(
        string stringSid,
        out IntPtr sid);

    [DllImport("advapi32.dll")]
    private static extern int GetLengthSid(IntPtr sid);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthorityCount(
        IntPtr sid);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthority(
        IntPtr sid,
        uint subAuthority);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessWithTokenW(
        IntPtr token,
        uint logonFlags,
        string applicationName,
        StringBuilder commandLine,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    public static WiciRestrictedLaunchResult Run(
        string applicationName,
        string arguments,
        int timeoutMilliseconds)
    {
        if (!ConvertStringSidToSidW(
                "S-1-5-32-544",
                out var administratorsSid))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "ConvertStringSidToSidW(Administrators) failed.");
        }

        IntPtr sourceToken = IntPtr.Zero;
        IntPtr restrictedToken = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(
                    GetCurrentProcess(),
                    TOKEN_QUERY |
                    TOKEN_DUPLICATE |
                    TOKEN_ASSIGN_PRIMARY |
                    TOKEN_ADJUST_DEFAULT,
                    out sourceToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "OpenProcessToken failed.");
            }

            var disabled = new[]
            {
                new SID_AND_ATTRIBUTES
                {
                    Sid = administratorsSid,
                    Attributes = 0
                }
            };

            if (!CreateRestrictedToken(
                    sourceToken,
                    DISABLE_MAX_PRIVILEGE | LUA_TOKEN,
                    1,
                    disabled,
                    0,
                    IntPtr.Zero,
                    0,
                    IntPtr.Zero,
                    out restrictedToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateRestrictedToken failed.");
            }

            SetMediumIntegrity(restrictedToken);

            var startup = new STARTUPINFO
            {
                cb = Marshal.SizeOf<STARTUPINFO>()
            };
            var commandLine = new StringBuilder(
                "\"" + applicationName + "\"" +
                (string.IsNullOrWhiteSpace(arguments)
                    ? ""
                    : " " + arguments));

            var currentDirectory =
                System.IO.Path.GetDirectoryName(applicationName);
            if (string.IsNullOrWhiteSpace(currentDirectory))
                currentDirectory = Environment.CurrentDirectory;

            if (!CreateProcessWithTokenW(
                    restrictedToken,
                    0,
                    applicationName,
                    commandLine,
                    CREATE_NO_WINDOW,
                    IntPtr.Zero,
                    currentDirectory,
                    ref startup,
                    out var created))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateProcessWithTokenW failed.");
            }

            try
            {
                var integrityRid =
                    GetIntegrityRid(created.hProcess);
                var wait = WaitForSingleObject(
                    created.hProcess,
                    (uint)timeoutMilliseconds);
                if (wait == WAIT_TIMEOUT)
                {
                    TerminateProcess(created.hProcess, 1223);
                    throw new TimeoutException(
                        "Restricted process timed out.");
                }

                if (wait != WAIT_OBJECT_0)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "WaitForSingleObject failed.");
                }

                if (!GetExitCodeProcess(
                        created.hProcess,
                        out var exitCode))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetExitCodeProcess failed.");
                }

                return new WiciRestrictedLaunchResult
                {
                    ProcessId = (int)created.dwProcessId,
                    IntegrityRid = integrityRid,
                    ExitCode = (int)exitCode
                };
            }
            finally
            {
                CloseHandle(created.hThread);
                CloseHandle(created.hProcess);
            }
        }
        finally
        {
            if (restrictedToken != IntPtr.Zero)
                CloseHandle(restrictedToken);
            if (sourceToken != IntPtr.Zero)
                CloseHandle(sourceToken);
            LocalFree(administratorsSid);
        }
    }

    private static int GetIntegrityRid(IntPtr process)
    {
        if (!OpenProcessToken(
                process,
                TOKEN_QUERY,
                out var token))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "OpenProcessToken(target) failed.");
        }

        try
        {
            GetTokenInformation(
                token,
                TokenIntegrityLevel,
                IntPtr.Zero,
                0,
                out var required);
            if (required <= 0)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "TokenIntegrityLevel size query failed.");
            }

            var buffer = Marshal.AllocHGlobal(required);
            try
            {
                if (!GetTokenInformation(
                        token,
                        TokenIntegrityLevel,
                        buffer,
                        required,
                        out _))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "TokenIntegrityLevel query failed.");
                }

                var label =
                    Marshal.PtrToStructure<TOKEN_MANDATORY_LABEL>(
                        buffer);
                var countPointer =
                    GetSidSubAuthorityCount(
                        label.Label.Sid);
                if (countPointer == IntPtr.Zero)
                    throw new InvalidOperationException(
                        "Integrity SID subauthority count unavailable.");

                var count =
                    Marshal.ReadByte(countPointer);
                if (count == 0)
                    throw new InvalidOperationException(
                        "Integrity SID contained no subauthorities.");

                var ridPointer =
                    GetSidSubAuthority(
                        label.Label.Sid,
                        (uint)(count - 1));
                if (ridPointer == IntPtr.Zero)
                    throw new InvalidOperationException(
                        "Integrity RID unavailable.");

                return Marshal.ReadInt32(ridPointer);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        finally
        {
            CloseHandle(token);
        }
    }

    private static void SetMediumIntegrity(
        IntPtr token)
    {
        if (!ConvertStringSidToSidW(
                "S-1-16-8192",
                out var mediumSid))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "ConvertStringSidToSidW(Medium) failed.");
        }

        try
        {
            var label = new TOKEN_MANDATORY_LABEL
            {
                Label = new SID_AND_ATTRIBUTES
                {
                    Sid = mediumSid,
                    Attributes = SE_GROUP_INTEGRITY
                }
            };
            var pointer =
                Marshal.AllocHGlobal(
                    Marshal.SizeOf<TOKEN_MANDATORY_LABEL>());
            try
            {
                Marshal.StructureToPtr(
                    label,
                    pointer,
                    false);
                var length =
                    Marshal.SizeOf<TOKEN_MANDATORY_LABEL>() +
                    GetLengthSid(mediumSid);

                if (!SetTokenInformation(
                        token,
                        TokenIntegrityLevel,
                        pointer,
                        length))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetTokenInformation(TokenIntegrityLevel) failed.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }
        }
        finally
        {
            LocalFree(mediumSid);
        }
    }
}
"@

function Invoke-Restricted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string]$Arguments = "",
        [int]$TimeoutMilliseconds = 180000
    )

    $result = [WiciRestrictedLauncher]::Run(
        $FilePath,
        $Arguments,
        $TimeoutMilliseconds)

    if ($result.IntegrityRid -ge 0x3000) {
        throw "Restricted process was not medium integrity. RID=$($result.IntegrityRid)"
    }

    return $result
}

function Get-RegistryString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        return Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

$artifactsDir =
    Join-Path (Split-Path -Parent $PSScriptRoot) "artifacts\security-lifecycle"
New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

$legacyInstaller =
    Join-Path $artifactsDir "WindowsImeCaretIndicator-Setup-0.1.0.exe"
Invoke-WebRequest -Uri $LegacyInstallerUrl -OutFile $legacyInstaller

$installerHash =
    (Get-FileHash -LiteralPath $legacyInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal -Expected $LegacyInstallerSha256 -Actual $installerHash -Message "Formal v0.1.0 installer checksum mismatch."

$legacyDir =
    Join-Path $env:LOCALAPPDATA "Programs\Windows IME Caret Indicator"
$legacyExe =
    Join-Path $legacyDir "WindowsImeCaretIndicator.exe"
$stateRoot =
    Join-Path $env:LOCALAPPDATA "WindowsImeCaretIndicator"
$legacySettings =
    Join-Path $stateRoot "settings.json"
$newSettings =
    Join-Path $stateRoot "StateV2\settings.json"
$runKey =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$legacyRunName = "WindowsImeCaretIndicator"
$newRunName = "WindowsImeCaretIndicator.v2"
$legacyUninstallKey =
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{77D81AE7-1E91-56DB-B694-8E60C764A76D}_is1"

Remove-ItemProperty -LiteralPath $runKey -Name $legacyRunName -ErrorAction SilentlyContinue
Remove-ItemProperty -LiteralPath $runKey -Name $newRunName -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $legacyUninstallKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $legacyDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue

$legacyInstall =
    Invoke-Restricted -FilePath $legacyInstaller -Arguments "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
Assert-Equal -Expected 0 -Actual $legacyInstall.ExitCode -Message "Formal v0.1.0 per-user install failed."

if (-not (Test-Path -LiteralPath $legacyExe)) {
    throw "Formal v0.1.0 executable was not installed in LocalAppData."
}

$legacyExeHash =
    (Get-FileHash -LiteralPath $legacyExe -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal -Expected $LegacyExecutableSha256 -Actual $legacyExeHash -Message "Formal v0.1.0 installed executable checksum mismatch."

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
@{
    StartWithWindows = $true
    Paused = $true
} | ConvertTo-Json | Set-Content -LiteralPath $legacySettings -Encoding utf8

$expectedLegacyRun = '"' + $legacyExe + '"'
$legacyRun = Get-RegistryString -Path $runKey -Name $legacyRunName
Assert-Equal -Expected $expectedLegacyRun -Actual $legacyRun -Message "Formal v0.1.0 startup value is not the expected product path."

$legacyUninstaller =
    Get-ChildItem -LiteralPath $legacyDir -Filter "unins*.exe" |
    Select-Object -First 1
if (-not $legacyUninstaller) {
    throw "Formal v0.1.0 uninstaller was not found."
}

$legacyUninstallerCopyDir =
    Join-Path $artifactsDir "legacy-uninstaller-copy"
New-Item -ItemType Directory -Path $legacyUninstallerCopyDir -Force | Out-Null
Get-ChildItem -LiteralPath $legacyDir -Filter "unins*.*" |
    Copy-Item -Destination $legacyUninstallerCopyDir -Force
$legacyUninstallerCopy =
    Get-ChildItem -LiteralPath $legacyUninstallerCopyDir -Filter "unins*.exe" |
    Select-Object -First 1

$candidateInstall =
    Start-Process -FilePath $CandidateInstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
Assert-Equal -Expected 0 -Actual $candidateInstall.ExitCode -Message "v0.1.1 candidate install failed."

$installDir =
    Join-Path $env:ProgramFiles "Windows IME Caret Indicator"
$installedExe =
    Join-Path $installDir "WindowsImeCaretIndicator.exe"
if (-not (Test-Path -LiteralPath $installedExe)) {
    throw "Protected v0.1.1 executable was not installed."
}

$legacyRunAfterElevatedInstall =
    Get-RegistryString -Path $runKey -Name $legacyRunName
Assert-Equal -Expected $expectedLegacyRun -Actual $legacyRunAfterElevatedInstall -Message "Already-elevated silent install unexpectedly mutated the original user's legacy startup state."

if (Test-Path -LiteralPath $newSettings) {
    throw "Already-elevated silent install unexpectedly migrated current-user settings."
}

$protectedCheck =
    Invoke-Restricted -FilePath $installedExe -Arguments "--verify-protected-install"
Assert-Equal -Expected 0 -Actual $protectedCheck.ExitCode -Message "Protected installed target did not pass fail-closed trust validation."

$selfTest =
    Invoke-Restricted -FilePath $installedExe -Arguments "--self-test"
Assert-Equal -Expected 0 -Actual $selfTest.ExitCode -Message "Installed candidate deterministic self-tests failed."

$migration =
    Invoke-Restricted -FilePath $installedExe -Arguments "--migrate-v0.1.0"
Assert-Equal -Expected 0 -Actual $migration.ExitCode -Message "Current-user v0.1.0 migration failed."

if (-not (Test-Path -LiteralPath $newSettings)) {
    throw "Migrated v0.1.1 settings file was not created."
}

$newState =
    Get-Content -LiteralPath $newSettings -Raw |
    ConvertFrom-Json
Assert-Equal -Expected $true -Actual ([bool]$newState.StartWithWindows) -Message "StartWithWindows was not preserved."
Assert-Equal -Expected $true -Actual ([bool]$newState.Paused) -Message "Paused was not preserved."
Assert-Equal -Expected ([IO.Path]::GetFullPath($installedExe)) -Actual ([IO.Path]::GetFullPath([string]$newState.InstallExecutablePath)) -Message "Migrated settings are not bound to the protected installed executable."

$expectedNewRun =
    '"' + ([IO.Path]::GetFullPath($installedExe)) + '"'
$newRun =
    Get-RegistryString -Path $runKey -Name $newRunName
Assert-Equal -Expected $expectedNewRun -Actual $newRun -Message "v0.1.1 startup value does not target the protected executable."

if ($null -ne (Get-RegistryString -Path $runKey -Name $legacyRunName)) {
    throw "Legacy v0.1.0 startup value remains authoritative after migration."
}

if (Test-Path -LiteralPath $legacySettings) {
    throw "Legacy v0.1.0 settings file remains after successful migration."
}

if (Test-Path -LiteralPath $legacyUninstallKey) {
    throw "Legacy v0.1.0 uninstall registration remains after validated migration."
}

if (Test-Path -LiteralPath $legacyExe) {
    throw "Legacy user-writable v0.1.0 executable remains after validated migration."
}

$oldUninstall =
    Invoke-Restricted -FilePath $legacyUninstallerCopy.FullName -Arguments "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
if ($oldUninstall.ExitCode -ne 0) {
    Write-Host "Copied v0.1.0 uninstaller returned $($oldUninstall.ExitCode); checking clobber resistance anyway."
}

Assert-Equal -Expected $expectedNewRun -Actual (Get-RegistryString -Path $runKey -Name $newRunName) -Message "Old v0.1.0 uninstaller clobbered the v0.1.1 startup value."

if (-not (Test-Path -LiteralPath $newSettings)) {
    throw "Old v0.1.0 uninstaller clobbered the v0.1.1 settings."
}

$originalAcl =
    Get-Acl -LiteralPath $installDir
$currentSid =
    [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$grantSpec =
    "*" + $currentSid + ":(OI)(CI)M"

try {
    & icacls.exe $installDir /grant $grantSpec | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to weaken the candidate install ACL for the negative test."
    }

    $weakenedCheck =
        Invoke-Restricted -FilePath $installedExe -Arguments "--verify-protected-install"
    if ($weakenedCheck.ExitCode -eq 0) {
        throw "Fail-closed trust validation accepted an ACL-weakened install directory."
    }
}
finally {
    Set-Acl -LiteralPath $installDir -AclObject $originalAcl
}

$restoredCheck =
    Invoke-Restricted -FilePath $installedExe -Arguments "--verify-protected-install"
Assert-Equal -Expected 0 -Actual $restoredCheck.ExitCode -Message "Protected target validation did not recover after restoring the ACL."

$candidateUninstaller =
    Get-ChildItem -LiteralPath $installDir -Filter "unins*.exe" |
    Select-Object -First 1
if (-not $candidateUninstaller) {
    throw "v0.1.1 candidate uninstaller was not found."
}

$candidateUninstall =
    Start-Process -FilePath $candidateUninstaller.FullName -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait -PassThru
Assert-Equal -Expected 0 -Actual $candidateUninstall.ExitCode -Message "v0.1.1 candidate uninstall failed."

if (Test-Path -LiteralPath $installedExe) {
    throw "Protected candidate executable remains after uninstall."
}

if ($null -ne (Get-RegistryString -Path $runKey -Name $newRunName)) {
    throw "v0.1.1 uninstall left the owned startup value behind."
}

if (Test-Path -LiteralPath $newSettings) {
    throw "v0.1.1 uninstall left owned current-user settings behind."
}

Write-Host "Security lifecycle smoke passed: formal v0.1.0 to protected v0.1.1 migration, old-uninstaller clobber resistance, ACL fail-closed validation, and current-credential uninstall cleanup."
