$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class WiciMediumRunResult
{
    public int ProcessId { get; set; }
    public int IntegrityRid { get; set; }
    public int ExitCode { get; set; }
}

public static class WiciRestrictedMediumRunner
{
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint MAXIMUM_ALLOWED = 0x02000000;
    private const uint DISABLE_MAX_PRIVILEGE = 0x00000001;
    private const int TokenIntegrityLevel = 25;
    private const uint SE_GROUP_INTEGRITY = 0x00000020;
    private const int SecurityImpersonation = 2;
    private const int TokenPrimary = 1;
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
    private static extern bool CreateRestrictedToken(
        IntPtr existingTokenHandle,
        uint flags,
        uint disableSidCount,
        IntPtr sidsToDisable,
        uint deletePrivilegeCount,
        IntPtr privilegesToDelete,
        uint restrictedSidCount,
        IntPtr sidsToRestrict,
        out IntPtr newTokenHandle);

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

    public static WiciMediumRunResult Start(
        string applicationName,
        string commandLine,
        string currentDirectory)
    {
        return Start(
            applicationName,
            commandLine,
            currentDirectory,
            0);
    }

    public static WiciMediumRunResult Start(
        string applicationName,
        string commandLine,
        string currentDirectory,
        int waitForExitMilliseconds)
    {
        IntPtr sourceToken = IntPtr.Zero;
        IntPtr primaryToken = IntPtr.Zero;
        IntPtr restrictedToken = IntPtr.Zero;
        IntPtr adminSid = IntPtr.Zero;
        IntPtr disableSidBuffer = IntPtr.Zero;

        if (!OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY | TOKEN_DUPLICATE,
                out sourceToken))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "OpenProcessToken failed.");
        }

        try
        {
            if (!DuplicateTokenEx(
                    sourceToken,
                    MAXIMUM_ALLOWED,
                    IntPtr.Zero,
                    SecurityImpersonation,
                    TokenPrimary,
                    out primaryToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "DuplicateTokenEx failed.");
            }

            if (!ConvertStringSidToSidW(
                    "S-1-5-32-544",
                    out adminSid))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "ConvertStringSidToSidW(Administrators) failed.");
            }

            var adminDisable = new SID_AND_ATTRIBUTES
            {
                Sid = adminSid,
                Attributes = 0
            };
            disableSidBuffer = Marshal.AllocHGlobal(
                Marshal.SizeOf<SID_AND_ATTRIBUTES>());
            Marshal.StructureToPtr(
                adminDisable,
                disableSidBuffer,
                false);

            if (!CreateRestrictedToken(
                    primaryToken,
                    DISABLE_MAX_PRIVILEGE,
                    1,
                    disableSidBuffer,
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
                cb = Marshal.SizeOf<STARTUPINFO>(),
                lpDesktop = @"winsta0\default"
            };
            var mutableCommandLine = new StringBuilder(commandLine);

            if (!CreateProcessWithTokenW(
                    restrictedToken,
                    0,
                    applicationName,
                    mutableCommandLine,
                    0,
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
                var rid = GetIntegrityRid(created.hProcess);
                var exitCode = 259;
                if (waitForExitMilliseconds > 0)
                {
                    var wait = WaitForSingleObject(
                        created.hProcess,
                        (uint)waitForExitMilliseconds);
                    if (wait == WAIT_TIMEOUT)
                    {
                        TerminateProcess(created.hProcess, 1223);
                        throw new TimeoutException(
                            "Restricted medium process timed out.");
                    }
                    if (wait != WAIT_OBJECT_0)
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "WaitForSingleObject failed.");
                    }
                    if (!GetExitCodeProcess(created.hProcess, out var rawExitCode))
                    {
                        throw new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "GetExitCodeProcess failed.");
                    }
                    exitCode = (int)rawExitCode;
                }

                return new WiciMediumRunResult
                {
                    ProcessId = (int)created.dwProcessId,
                    IntegrityRid = rid,
                    ExitCode = exitCode
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
            if (disableSidBuffer != IntPtr.Zero)
                Marshal.FreeHGlobal(disableSidBuffer);
            if (adminSid != IntPtr.Zero)
                LocalFree(adminSid);
            if (restrictedToken != IntPtr.Zero)
                CloseHandle(restrictedToken);
            if (primaryToken != IntPtr.Zero)
                CloseHandle(primaryToken);
            if (sourceToken != IntPtr.Zero)
                CloseHandle(sourceToken);
        }
    }

    private static int GetIntegrityRid(IntPtr process)
    {
        if (!OpenProcessToken(process, TOKEN_QUERY, out var token))
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

                var label = Marshal.PtrToStructure<TOKEN_MANDATORY_LABEL>(buffer);
                var countPointer = GetSidSubAuthorityCount(label.Label.Sid);
                if (countPointer == IntPtr.Zero)
                    throw new InvalidOperationException("Integrity SID count unavailable.");
                var count = Marshal.ReadByte(countPointer);
                var ridPointer = GetSidSubAuthority(
                    label.Label.Sid,
                    (uint)(count - 1));
                if (ridPointer == IntPtr.Zero)
                    throw new InvalidOperationException("Integrity SID RID unavailable.");
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
        if (!ConvertStringSidToSidW("S-1-16-8192", out var mediumSid))
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
            var labelPointer = Marshal.AllocHGlobal(
                Marshal.SizeOf<TOKEN_MANDATORY_LABEL>());
            try
            {
                Marshal.StructureToPtr(label, labelPointer, false);
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

function Start-WiciRestrictedMediumProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Role = "runtime"
    )

    $resolved = (Resolve-Path -LiteralPath $FilePath).Path
    $commandLine = '"' + $resolved + '"'
    foreach ($argument in $ArgumentList) {
        if ($argument.Contains('"')) {
            throw "Unsupported quote character in restricted-process argument."
        }
        if ($argument -match '\s') {
            $commandLine += ' "' + $argument + '"'
        }
        else {
            $commandLine += ' ' + $argument
        }
    }

    $result = [WiciRestrictedMediumRunner]::Start(
        $resolved,
        $commandLine,
        (Get-Location).Path)

    if ($result.IntegrityRid -lt 0x2000 -or
        $result.IntegrityRid -ge 0x3000) {
        throw "Restricted process '$Role' did not start at Medium integrity."
    }

    Write-Host (
        "WICI_RESTRICTED_MEDIUM_PROCESS role={0} pid={1} integrityRid={2}" -f
        $Role,
        $result.ProcessId,
        $result.IntegrityRid)

    return [System.Diagnostics.Process]::GetProcessById($result.ProcessId)
}

function Invoke-WiciRestrictedMediumProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Role = "runtime",
        [int]$TimeoutMilliseconds = 5000
    )

    $resolved = (Resolve-Path -LiteralPath $FilePath).Path
    $commandLine = '"' + $resolved + '"'
    foreach ($argument in $ArgumentList) {
        if ($argument.Contains('"')) {
            throw "Unsupported quote character in restricted-process argument."
        }
        if ($argument -match '\s') {
            $commandLine += ' "' + $argument + '"'
        }
        else {
            $commandLine += ' ' + $argument
        }
    }

    $result = [WiciRestrictedMediumRunner]::Start(
        $resolved,
        $commandLine,
        (Get-Location).Path,
        $TimeoutMilliseconds)

    if ($result.IntegrityRid -lt 0x2000 -or
        $result.IntegrityRid -ge 0x3000) {
        throw "Restricted process '$Role' did not run at Medium integrity."
    }

    Write-Host (
        "WICI_RESTRICTED_MEDIUM_COMPLETED role={0} pid={1} integrityRid={2} exitCode={3}" -f
        $Role,
        $result.ProcessId,
        $result.IntegrityRid,
        $result.ExitCode)

    return $result
}
