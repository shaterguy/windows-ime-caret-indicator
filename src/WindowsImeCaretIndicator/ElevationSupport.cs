using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace WindowsImeCaretIndicator;

internal sealed class SingleInstanceLease : IDisposable
{
    private readonly Mutex _mutex;
    private bool _ownsMutex;

    private SingleInstanceLease(Mutex mutex)
    {
        _mutex = mutex;
        _ownsMutex = true;
    }

    internal static SingleInstanceLease? TryAcquire(
        string name,
        TimeSpan wait)
    {
        var mutex = new Mutex(initiallyOwned: false, name);
        var acquired = false;

        try
        {
            try
            {
                acquired = wait > TimeSpan.Zero
                    ? mutex.WaitOne(wait)
                    : mutex.WaitOne(0);
            }
            catch (AbandonedMutexException)
            {
                acquired = true;
            }

            if (!acquired)
            {
                mutex.Dispose();
                return null;
            }

            return new SingleInstanceLease(mutex);
        }
        catch
        {
            if (!acquired)
                mutex.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (!_ownsMutex)
            return;

        _ownsMutex = false;
        try
        {
            _mutex.ReleaseMutex();
        }
        finally
        {
            _mutex.Dispose();
        }
    }
}

internal static class ProductInstallIdentity
{
    internal const string ProductDirectoryName =
        "Windows IME Caret Indicator";
    internal const string ExecutableName =
        "WindowsImeCaretIndicator.exe";

    internal static string InstalledDirectory =>
        Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.ProgramFiles),
            ProductDirectoryName);

    internal static string InstalledExecutable =>
        Path.Combine(InstalledDirectory, ExecutableName);

    internal static bool IsExpectedInstalledExecutable(
        string? executable)
    {
        if (string.IsNullOrWhiteSpace(executable))
            return false;

        try
        {
            return string.Equals(
                Path.GetFullPath(InstalledExecutable),
                Path.GetFullPath(executable),
                StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}

internal static class ElevationSupport
{
    internal static bool IsElevated
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(
                WindowsBuiltInRole.Administrator);
        }
    }

    internal static bool CanRestartElevated
    {
        get
        {
            if (IsElevated)
                return false;

            var executable = Environment.ProcessPath;
            return !string.IsNullOrWhiteSpace(executable) &&
                   IsProtectedElevationTarget(executable);
        }
    }

    internal static bool IsProtectedElevationTarget(
        string executable)
    {
        try
        {
            if (!ProductInstallIdentity
                    .IsExpectedInstalledExecutable(executable))
            {
                return false;
            }

            var fullPath = Path.GetFullPath(executable);
            var programFiles = Path.GetFullPath(
                Environment.GetFolderPath(
                    Environment.SpecialFolder.ProgramFiles));
            var installDirectory = Path.GetFullPath(
                ProductInstallIdentity.InstalledDirectory);

            var exists = File.Exists(fullPath);
            var hasReparsePoint =
                HasReparsePoint(programFiles) ||
                HasReparsePoint(installDirectory) ||
                HasReparsePoint(fullPath);
            var unsafeEffectiveAccess =
                CurrentUserHasUnsafeEffectiveAccess(programFiles) ||
                CurrentUserHasUnsafeEffectiveAccess(installDirectory) ||
                CurrentUserHasUnsafeEffectiveAccess(fullPath);

            return EvaluateTargetTrust(
                exactProductPath: true,
                exists,
                hasReparsePoint,
                unsafeEffectiveAccess,
                validationSucceeded: true);
        }
        catch
        {
            return false;
        }
    }

    internal static bool EvaluateTargetTrust(
        bool exactProductPath,
        bool exists,
        bool hasReparsePoint,
        bool unsafeEffectiveAccess,
        bool validationSucceeded) =>
        exactProductPath &&
        exists &&
        !hasReparsePoint &&
        !unsafeEffectiveAccess &&
        validationSucceeded;

    private static bool HasReparsePoint(string path)
    {
        var attributes = File.GetAttributes(path);
        return (attributes & FileAttributes.ReparsePoint) != 0;
    }

    private static bool CurrentUserHasUnsafeEffectiveAccess(
        string path)
    {
        var grantedAccess =
            FileSystemAccessCheck.GetMaximumAllowedAccess(path);
        return (grantedAccess &
                FileSystemAccessCheck.UnsafeMutationRights) != 0;
    }

    internal static ProcessStartInfo CreateRestartStartInfo(
        string executable) =>
        new()
        {
            FileName = executable,
            Arguments = "--wait-for-instance",
            UseShellExecute = true,
            Verb = "runas"
        };

    internal static bool TryRestartElevated()
    {
        if (IsElevated)
            return false;

        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) ||
            !IsProtectedElevationTarget(executable))
        {
            return false;
        }

        try
        {
            using var process = Process.Start(
                CreateRestartStartInfo(executable));
            return process is not null;
        }
        catch (Win32Exception)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }
}

internal static class FileSystemAccessCheck
{
    internal const uint UnsafeMutationRights =
        0x00000002 |
        0x00000004 |
        0x00000010 |
        0x00000040 |
        0x00000100 |
        0x00010000 |
        0x00040000 |
        0x00080000;

    private const uint OwnerSecurityInformation = 0x00000001;
    private const uint GroupSecurityInformation = 0x00000002;
    private const uint DaclSecurityInformation = 0x00000004;
    private const int SeFileObject = 1;

    private const uint TokenQuery = 0x0008;
    private const uint TokenDuplicate = 0x0002;
    private const int SecurityImpersonation = 2;
    private const uint MaximumAllowed = 0x02000000;
    private const int ErrorInsufficientBuffer = 122;

    private const uint FileGenericRead = 0x00120089;
    private const uint FileGenericWrite = 0x00120116;
    private const uint FileGenericExecute = 0x001200A0;
    private const uint FileAllAccess = 0x001F01FF;

    [StructLayout(LayoutKind.Sequential)]
    private struct GenericMapping
    {
        public uint GenericRead;
        public uint GenericWrite;
        public uint GenericExecute;
        public uint GenericAll;
    }

    internal static uint GetMaximumAllowedAccess(
        string path)
    {
        var result = GetNamedSecurityInfo(
            path,
            SeFileObject,
            OwnerSecurityInformation |
            GroupSecurityInformation |
            DaclSecurityInformation,
            out _,
            out _,
            out _,
            out _,
            out var securityDescriptor);

        if (result != 0 || securityDescriptor == IntPtr.Zero)
        {
            throw new Win32Exception(
                unchecked((int)result),
                "Unable to read file-system security.");
        }

        IntPtr processToken = IntPtr.Zero;
        IntPtr impersonationToken = IntPtr.Zero;
        IntPtr privilegeSet = IntPtr.Zero;

        try
        {
            if (!OpenProcessToken(
                    GetCurrentProcess(),
                    TokenQuery | TokenDuplicate,
                    out processToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Unable to open the current process token.");
            }

            if (!DuplicateToken(
                    processToken,
                    SecurityImpersonation,
                    out impersonationToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Unable to duplicate the current process token.");
            }

            var mapping = new GenericMapping
            {
                GenericRead = FileGenericRead,
                GenericWrite = FileGenericWrite,
                GenericExecute = FileGenericExecute,
                GenericAll = FileAllAccess
            };

            uint privilegeSetLength = 0;
            var firstSucceeded = AccessCheck(
                securityDescriptor,
                impersonationToken,
                MaximumAllowed,
                ref mapping,
                IntPtr.Zero,
                ref privilegeSetLength,
                out var grantedAccess,
                out var accessStatus);

            if (firstSucceeded)
                return accessStatus ? grantedAccess : 0;

            var firstError = Marshal.GetLastWin32Error();
            if (firstError != ErrorInsufficientBuffer ||
                privilegeSetLength == 0)
            {
                throw new Win32Exception(
                    firstError,
                    "Unable to size AccessCheck privileges.");
            }

            privilegeSet = Marshal.AllocHGlobal(
                checked((int)privilegeSetLength));

            if (!AccessCheck(
                    securityDescriptor,
                    impersonationToken,
                    MaximumAllowed,
                    ref mapping,
                    privilegeSet,
                    ref privilegeSetLength,
                    out grantedAccess,
                    out accessStatus))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Unable to evaluate effective file-system access.");
            }

            return accessStatus ? grantedAccess : 0;
        }
        finally
        {
            if (privilegeSet != IntPtr.Zero)
                Marshal.FreeHGlobal(privilegeSet);
            if (impersonationToken != IntPtr.Zero)
                _ = CloseHandle(impersonationToken);
            if (processToken != IntPtr.Zero)
                _ = CloseHandle(processToken);
            _ = LocalFree(securityDescriptor);
        }
    }

    [DllImport(
        "advapi32.dll",
        CharSet = CharSet.Unicode)]
    private static extern uint GetNamedSecurityInfo(
        string pObjectName,
        int objectType,
        uint securityInfo,
        out IntPtr owner,
        out IntPtr group,
        out IntPtr dacl,
        out IntPtr sacl,
        out IntPtr securityDescriptor);

    [DllImport(
        "advapi32.dll",
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out IntPtr tokenHandle);

    [DllImport(
        "advapi32.dll",
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateToken(
        IntPtr existingToken,
        int impersonationLevel,
        out IntPtr duplicateToken);

    [DllImport(
        "advapi32.dll",
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AccessCheck(
        IntPtr securityDescriptor,
        IntPtr clientToken,
        uint desiredAccess,
        ref GenericMapping genericMapping,
        IntPtr privilegeSet,
        ref uint privilegeSetLength,
        out uint grantedAccess,
        [MarshalAs(UnmanagedType.Bool)] out bool accessStatus);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport(
        "kernel32.dll",
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(
        IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(
        IntPtr memory);
}
