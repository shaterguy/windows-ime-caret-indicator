param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [string]$WebView2HostPath
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class WiciTokenLaunchResult
{
    public int ProcessId { get; set; }
    public int IntegrityRid { get; set; }
    public int ExitCode { get; set; }
}

public static class WiciIntegrityNative
{
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint TOKEN_ADJUST_DEFAULT = 0x0080;
    private const uint MAXIMUM_ALLOWED = 0x02000000;
    private const int TokenIntegrityLevel = 25;
    private const uint SE_GROUP_INTEGRITY = 0x00000020;
    private const int SecurityImpersonation = 2;
    private const int TokenPrimary = 1;
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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthority(
        IntPtr sid,
        uint subAuthority);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateTokenEx(
        IntPtr existingToken,
        uint desiredAccess,
        IntPtr tokenAttributes,
        int impersonationLevel,
        int tokenType,
        out IntPtr newToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSidToSidW(
        string stringSid,
        out IntPtr sid);

    [DllImport("advapi32.dll")]
    private static extern int GetLengthSid(IntPtr sid);

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
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static int GetProcessIntegrityRid(int processId)
    {
        var process = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            (uint)processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "OpenProcess failed.");

        try
        {
            return GetIntegrityRidFromProcess(process);
        }
        finally
        {
            CloseHandle(process);
        }
    }

    public static WiciTokenLaunchResult LaunchWithProcessToken(
        int sourceProcessId,
        string applicationName,
        string commandLine,
        string currentDirectory,
        bool lowerToMedium,
        int timeoutMilliseconds)
    {
        var sourceProcess = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            (uint)sourceProcessId);
        if (sourceProcess == IntPtr.Zero)
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "OpenProcess for source token failed.");

        IntPtr sourceToken = IntPtr.Zero;
        IntPtr launchToken = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(
                    sourceProcess,
                    TOKEN_QUERY | TOKEN_DUPLICATE,
                    out sourceToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "OpenProcessToken for source failed.");
            }

            if (!DuplicateTokenEx(
                    sourceToken,
                    MAXIMUM_ALLOWED,
                    IntPtr.Zero,
                    SecurityImpersonation,
                    TokenPrimary,
                    out launchToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "DuplicateTokenEx failed.");
            }

            if (lowerToMedium)
                SetMediumIntegrity(launchToken);

            var startup = new STARTUPINFO
            {
                cb = Marshal.SizeOf<STARTUPINFO>()
            };
            var mutableCommandLine = new StringBuilder(commandLine);
            if (!CreateProcessWithTokenW(
                    launchToken,
                    0,
                    applicationName,
                    mutableCommandLine,
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
                var rid = GetIntegrityRidFromProcess(created.hProcess);
                var wait = WaitForSingleObject(
                    created.hProcess,
                    (uint)timeoutMilliseconds);
                if (wait == WAIT_TIMEOUT)
                {
                    TerminateProcess(created.hProcess, 1223);
                    throw new TimeoutException(
                        "Token-launched process did not exit in time.");
                }
                if (wait != WAIT_OBJECT_0)
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "WaitForSingleObject failed.");
                }
                if (!GetExitCodeProcess(created.hProcess, out var exitCode))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "GetExitCodeProcess failed.");
                }

                return new WiciTokenLaunchResult
                {
                    ProcessId = (int)created.dwProcessId,
                    IntegrityRid = rid,
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
            if (launchToken != IntPtr.Zero)
                CloseHandle(launchToken);
            if (sourceToken != IntPtr.Zero)
                CloseHandle(sourceToken);
            CloseHandle(sourceProcess);
        }
    }

    private static int GetIntegrityRidFromProcess(IntPtr process)
    {
        if (!OpenProcessToken(process, TOKEN_QUERY, out var token))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "OpenProcessToken failed.");
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
                    GetSidSubAuthorityCount(label.Label.Sid);
                if (countPointer == IntPtr.Zero)
                    throw new InvalidOperationException(
                        "Integrity SID subauthority count was unavailable.");

                var count = Marshal.ReadByte(countPointer);
                if (count == 0)
                    throw new InvalidOperationException(
                        "Integrity SID contained no subauthorities.");

                var ridPointer = GetSidSubAuthority(
                    label.Label.Sid,
                    (uint)(count - 1));
                if (ridPointer == IntPtr.Zero)
                    throw new InvalidOperationException(
                        "Integrity SID RID was unavailable.");

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

    private static void SetMediumIntegrity(IntPtr token)
    {
        if (!ConvertStringSidToSidW(
                "S-1-16-8192",
                out var mediumSid))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "ConvertStringSidToSidW failed.");
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
            var labelPointer = Marshal.AllocHGlobal(
                Marshal.SizeOf<TOKEN_MANDATORY_LABEL>());
            try
            {
                Marshal.StructureToPtr(
                    label,
                    labelPointer,
                    false);
                var length =
                    Marshal.SizeOf<TOKEN_MANDATORY_LABEL>() +
                    GetLengthSid(mediumSid);
                if (!SetTokenInformation(
                        token,
                        TokenIntegrityLevel,
                        labelPointer,
                        length))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetTokenInformation(TokenIntegrityLevel) failed.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(labelPointer);
            }
        }
        finally
        {
            LocalFree(mediumSid);
        }
    }
}
"@

function Get-IntegrityName {
    param([int]$Rid)

    if ($Rid -lt 0) { return "Unknown" }
    if ($Rid -lt 0x2000) { return "Low" }
    if ($Rid -lt 0x3000) { return "Medium" }
    if ($Rid -lt 0x4000) { return "High" }
    if ($Rid -lt 0x5000) { return "System" }
    return "Protected"
}

function Test-MediumIntegrity {
    param([int]$Rid)
    return $Rid -ge 0x2000 -and $Rid -lt 0x3000
}

function Wait-WebView2HostReady {
    param([System.Diagnostics.Process]$Process)

    for ($i = 0; $i -lt 120; $i++) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "WebView2 high-integrity host exited before becoming ready."
        }
        if ($Process.MainWindowHandle -ne 0 -and
            $Process.MainWindowTitle -like "*Ready*") {
            return
        }
        Start-Sleep -Milliseconds 100
    }

    throw "WebView2 high-integrity host did not become ready."
}

function Invoke-LocalProbe {
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
            throw "High-integrity baseline probe did not start."
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $all = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $all += ($stdout -split "\r?\n")
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $all += ($stderr -split "\r?\n")
        }
        $jsonLine = $all |
            Where-Object { $_ -match "^\s*\{" } |
            Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace($jsonLine)) {
            throw "High-integrity baseline probe produced no JSON: $($all -join ' | ')"
        }

        return [ordered]@{
            exitCode = $process.ExitCode
            probe = ($jsonLine | ConvertFrom-Json)
            output = @($all)
        }
    }
    finally {
        $process.Dispose()
    }
}

function Parse-TokenProbeOutput {
    param(
        [string]$OutputPath,
        [object]$Launch
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw (
            "Direct token-launched candidate did not create its probe output. " +
            "pid=$($Launch.ProcessId) integrityRid=$($Launch.IntegrityRid) " +
            "exitCode=$($Launch.ExitCode)")
    }

    $json = Get-Content -LiteralPath $OutputPath -Raw
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "Direct token-launched candidate wrote an empty probe output."
    }

    return [ordered]@{
        processId = $Launch.ProcessId
        integrityRid = $Launch.IntegrityRid
        integrityName = Get-IntegrityName $Launch.IntegrityRid
        exitCode = $Launch.ExitCode
        probe = ($json | ConvertFrom-Json)
    }
}

function Save-Evidence {
    param(
        [object]$Data,
        [string]$Path
    )

    $pretty = $Data | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $Path -Value $pretty -Encoding UTF8
    $compact = $Data | ConvertTo-Json -Depth 12 -Compress
    Write-Host "WICI_CROSS_INTEGRITY=$compact"
}

$ExecutablePath = (Resolve-Path $ExecutablePath).Path
$WebView2HostPath = (Resolve-Path $WebView2HostPath).Path
$artifactsDir = Join-Path (Get-Location) "artifacts"
New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
$evidencePath = Join-Path $artifactsDir "cross-integrity.json"
$mediumOutputPath = Join-Path $artifactsDir "cross-integrity-medium-probe.json"

$results = [ordered]@{
    status = "RUNNING"
    executable = [ordered]@{
        path = $ExecutablePath
        sha256 = (
            Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
    host = [ordered]@{
        path = $WebView2HostPath
    }
}

$target = $null
$shell = $null

try {
    $currentRid = [WiciIntegrityNative]::GetProcessIntegrityRid($PID)
    $currentSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $currentSession } |
        Sort-Object Id |
        Select-Object -First 1

    $explorerRid = -1
    if ($null -ne $explorer) {
        $explorerRid = [WiciIntegrityNative]::GetProcessIntegrityRid(
            $explorer.Id)
    }

    $results.environment = [ordered]@{
        currentProcessId = $PID
        currentIntegrityRid = $currentRid
        currentIntegrityName = Get-IntegrityName $currentRid
        sessionId = $currentSession
        explorerProcessId = if ($null -ne $explorer) {
            $explorer.Id
        } else {
            $null
        }
        explorerIntegrityRid = $explorerRid
        explorerIntegrityName = Get-IntegrityName $explorerRid
    }

    if ($currentRid -lt 0x3000) {
        $results.status = "ENVIRONMENT_LIMITATION"
        $results.limitation = (
            "The CI host process is not high integrity, so a measured high-target " +
            "baseline cannot be created without an interactive UAC elevation. " +
            "No UAC or Windows security policy was weakened."
        )
        Save-Evidence -Data $results -Path $evidencePath
        return
    }

    $target = Start-Process -FilePath $WebView2HostPath -PassThru
    Wait-WebView2HostReady -Process $target
    $targetRid = [WiciIntegrityNative]::GetProcessIntegrityRid($target.Id)
    if ($targetRid -lt 0x3000) {
        throw "WebView2 target inherited RID $targetRid instead of high integrity."
    }

    $shell = New-Object -ComObject WScript.Shell
    $activated = $false
    for ($i = 0; $i -lt 20; $i++) {
        if ($shell.AppActivate($target.Id)) {
            $activated = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $activated) {
        throw "Unable to activate the high-integrity WebView2 target."
    }
    Start-Sleep -Milliseconds 350

    $highProbe = Invoke-LocalProbe
    if ($highProbe.exitCode -ne 0 -or
        $highProbe.probe.activeCaret -ne $true) {
        throw (
            "High-integrity candidate baseline did not observe the high target. " +
            ($highProbe | ConvertTo-Json -Depth 8 -Compress))
    }
    if ([int]$highProbe.probe.process.integrityRid -lt 0x3000) {
        throw (
            "High baseline candidate ran below high integrity. RID=" +
            $highProbe.probe.process.integrityRid)
    }

    $commandLine = (
        '"' +
        $ExecutablePath +
        '" --probe-once-file "' +
        $mediumOutputPath +
        '"'
    )

    $launchKind = $null
    $sourcePid = $PID
    $lowerToMedium = $true
    if ($null -ne $explorer -and
        (Test-MediumIntegrity $explorerRid)) {
        $launchKind = "EXPLORER_PRIMARY_TOKEN"
        $sourcePid = $explorer.Id
        $lowerToMedium = $false
    }
    else {
        $launchKind = "LOWERED_CURRENT_TOKEN_FALLBACK"
    }

    $launch = [WiciIntegrityNative]::LaunchWithProcessToken(
        $sourcePid,
        $ExecutablePath,
        $commandLine,
        (Get-Location).Path,
        $lowerToMedium,
        30000)

    $results.mediumLaunch = [ordered]@{
        kind = $launchKind
        sourceProcessId = $sourcePid
        sourceIntegrityRid = if ($launchKind -eq "EXPLORER_PRIMARY_TOKEN") {
            $explorerRid
        } else {
            $currentRid
        }
        loweredToMedium = $lowerToMedium
        processId = $launch.ProcessId
        integrityRid = $launch.IntegrityRid
        integrityName = Get-IntegrityName $launch.IntegrityRid
        exitCode = $launch.ExitCode
    }

    $mediumProbe = Parse-TokenProbeOutput -OutputPath $mediumOutputPath -Launch $launch

    if (-not (Test-MediumIntegrity $mediumProbe.integrityRid)) {
        throw (
            "The direct token-launched candidate was not measured at medium integrity. RID=" +
            $mediumProbe.integrityRid)
    }
    if (-not (Test-MediumIntegrity (
            [int]$mediumProbe.probe.process.integrityRid))) {
        throw (
            "The actual candidate self-reported a non-medium integrity RID=" +
            $mediumProbe.probe.process.integrityRid)
    }
    if ($mediumProbe.exitCode -notin @(0, 3)) {
        throw (
            "The medium candidate returned an unexpected probe exit code " +
            "$($mediumProbe.exitCode).")
    }

    $results.highTarget = [ordered]@{
        processId = $target.Id
        integrityRid = $targetRid
        integrityName = Get-IntegrityName $targetRid
        readyTitle = $target.MainWindowTitle
    }
    $results.highProbe = $highProbe
    $results.mediumProbe = $mediumProbe
    $results.interpretation = if ($mediumProbe.probe.activeCaret -eq $true) {
        "MEASURED_MEDIUM_CANDIDATE_OBSERVED_HIGH_TARGET_CARET"
    } else {
        "MEASURED_MEDIUM_CANDIDATE_DID_NOT_OBSERVE_HIGH_TARGET_CARET"
    }
    $results.status = "MEASURED"

    Save-Evidence -Data $results -Path $evidencePath
}
catch {
    $results.status = "ERROR"
    $results.error = [ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        detail = $_.Exception.ToString()
    }
    Save-Evidence -Data $results -Path $evidencePath
    throw
}
finally {
    if ($null -ne $target) {
        try {
            $target.Refresh()
            if (-not $target.HasExited) {
                Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
                [void]$target.WaitForExit(5000)
            }
        }
        catch {
        }
        $target.Dispose()
    }
    if ($null -ne $shell) {
        try {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shell)
        }
        catch {
        }
    }
}
