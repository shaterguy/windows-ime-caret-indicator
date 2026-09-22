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

internal static class ElevationTargetPolicy
{
    internal static bool IsAccepted(
        bool exactTarget,
        bool targetExists,
        bool hasReparsePoint,
        bool currentUserHasUnsafeAccess,
        bool validationSucceeded) =>
        validationSucceeded &&
        exactTarget &&
        targetExists &&
        !hasReparsePoint &&
        !currentUserHasUnsafeAccess;
}

internal static class ElevationSupport
{
    private const string ProductDirectoryName =
        "Windows IME Caret Indicator";
    private const string ProductExecutableName =
        "WindowsImeCaretIndicator.exe";

    private const uint TokenQuery = 0x0008;
    private const uint TokenDuplicate = 0x0002;
    private const uint MaximumAllowed = 0x02000000;
    private const int SecurityImpersonation = 2;
    private const int ErrorInsufficientBuffer = 122;

    private const uint FileWriteData = 0x0002;
    private const uint FileAppendData = 0x0004;
    private const uint FileWriteEa = 0x0010;
    private const uint FileDeleteChild = 0x0040;
    private const uint FileWriteAttributes = 0x0100;
    private const uint Delete = 0x00010000;
    private const uint WriteDac = 0x00040000;
    private const uint WriteOwner = 0x00080000;

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

    internal static string? GetExpectedInstalledExecutablePath()
    {
        var programFiles = Environment.GetFolderPath(
            Environment.SpecialFolder.ProgramFiles);
        if (string.IsNullOrWhiteSpace(programFiles))
            return null;

        return Path.Combine(
            programFiles,
            ProductDirectoryName,
            ProductExecutableName);
    }

    internal static bool IsExpectedInstalledExecutablePath(
        string executable)
    {
        if (string.IsNullOrWhiteSpace(executable))
            return false;

        try
        {
            var expected = GetExpectedInstalledExecutablePath();
            if (string.IsNullOrWhiteSpace(expected))
                return false;

            var fullPath = Path.GetFullPath(executable);
            var expectedPath = Path.GetFullPath(expected);
            if (!string.Equals(
                    fullPath,
                    expectedPath,
                    StringComparison.OrdinalIgnoreCase) ||
                !File.Exists(fullPath))
            {
                return false;
            }

            var installDirectory =
                Path.GetDirectoryName(expectedPath);
            var programFiles =
                Environment.GetFolderPath(
                    Environment.SpecialFolder.ProgramFiles);

            if (string.IsNullOrWhiteSpace(installDirectory) ||
                string.IsNullOrWhiteSpace(programFiles) ||
                !Directory.Exists(programFiles) ||
                !Directory.Exists(installDirectory))
            {
                return false;
            }

            return !new[]
                {
                    Path.GetFullPath(programFiles),
                    Path.GetFullPath(installDirectory),
                    expectedPath
                }
                .Any(HasReparsePoint);
        }
        catch
        {
            return false;
        }
    }

    internal static bool IsProtectedElevationTarget(
        string executable)
    {
        if (!IsExpectedInstalledExecutablePath(executable))
            return false;

        try
        {
            var expectedPath = Path.GetFullPath(
                GetExpectedInstalledExecutablePath()!);
            var installDirectory =
                Path.GetDirectoryName(expectedPath)!;
            var programFiles =
                Path.GetFullPath(
                    Environment.GetFolderPath(
                        Environment.SpecialFolder.ProgramFiles));

            var currentUserHasUnsafeAccess =
                HasUnsafeEffectiveAccess(
                    programFiles,
                    directory: true) ||
                HasUnsafeEffectiveAccess(
                    installDirectory,
                    directory: true) ||
                HasUnsafeEffectiveAccess(
                    expectedPath,
                    directory: false);

            return ElevationTargetPolicy.IsAccepted(
                exactTarget: true,
                targetExists: true,
                hasReparsePoint: false,
                currentUserHasUnsafeAccess:
                    currentUserHasUnsafeAccess,
                validationSucceeded: true);
        }
        catch
        {
            return false;
        }
    }

    private static bool HasReparsePoint(
        string path)
    {
        var attributes =
            File.GetAttributes(path);
        return (attributes &
                FileAttributes.ReparsePoint) != 0;
    }

    private static bool HasUnsafeEffectiveAccess(
        string path,
        bool directory)
    {
        var securityResult =
            NativeMethods.GetNamedSecurityInfo(
                path,
                NativeMethods.SeFileObject,
                NativeMethods.DaclSecurityInformation,
                out _,
                out _,
                out _,
                out _,
                out var securityDescriptor);

        if (securityResult != 0 ||
            securityDescriptor == nint.Zero)
        {
            throw new Win32Exception(
                (int)securityResult,
                "Unable to read target security descriptor.");
        }

        nint processToken = nint.Zero;
        nint impersonationToken = nint.Zero;
        try
        {
            using var process =
                Process.GetCurrentProcess();
            if (!NativeMethods.OpenProcessToken(
                    process.Handle,
                    TokenQuery | TokenDuplicate,
                    out processToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "OpenProcessToken failed.");
            }

            if (!NativeMethods.DuplicateToken(
                    processToken,
                    SecurityImpersonation,
                    out impersonationToken))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "DuplicateToken failed.");
            }

            var mapping =
                new NativeMethods.GenericMapping
                {
                    GenericRead = 0x00120089,
                    GenericWrite = 0x00120116,
                    GenericExecute = 0x001200A0,
                    GenericAll = 0x001F01FF
                };

            uint privilegeSetLength = 0;
            var firstCall =
                NativeMethods.AccessCheck(
                    securityDescriptor,
                    impersonationToken,
                    MaximumAllowed,
                    ref mapping,
                    nint.Zero,
                    ref privilegeSetLength,
                    out var grantedAccess,
                    out var accessStatus);

            if (firstCall)
            {
                return accessStatus &&
                       HasUnsafeBits(
                           grantedAccess,
                           directory);
            }

            var initialError =
                Marshal.GetLastWin32Error();
            if (initialError !=
                    ErrorInsufficientBuffer ||
                privilegeSetLength == 0)
            {
                throw new Win32Exception(
                    initialError,
                    "AccessCheck size query failed.");
            }

            var privilegeSet =
                Marshal.AllocHGlobal(
                    checked(
                        (int)privilegeSetLength));
            try
            {
                if (!NativeMethods.AccessCheck(
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
                        "AccessCheck failed.");
                }

                return accessStatus &&
                       HasUnsafeBits(
                           grantedAccess,
                           directory);
            }
            finally
            {
                Marshal.FreeHGlobal(
                    privilegeSet);
            }
        }
        finally
        {
            if (impersonationToken != nint.Zero)
                _ = NativeMethods.CloseHandle(
                    impersonationToken);
            if (processToken != nint.Zero)
                _ = NativeMethods.CloseHandle(
                    processToken);
            _ = NativeMethods.LocalFree(
                securityDescriptor);
        }
    }

    private static bool HasUnsafeBits(
        uint grantedAccess,
        bool directory)
    {
        var dangerous =
            FileWriteData |
            FileAppendData |
            FileWriteEa |
            FileWriteAttributes |
            Delete |
            WriteDac |
            WriteOwner;

        if (directory)
            dangerous |= FileDeleteChild;

        return (grantedAccess &
                dangerous) != 0;
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

        var executable =
            Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) ||
            !IsProtectedElevationTarget(executable))
        {
            return false;
        }

        try
        {
            using var process =
                Process.Start(
                    CreateRestartStartInfo(
                        executable));
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

    private static class NativeMethods
    {
        internal const uint SeFileObject = 1;
        internal const uint DaclSecurityInformation =
            0x00000004;

        [StructLayout(LayoutKind.Sequential)]
        internal struct GenericMapping
        {
            internal uint GenericRead;
            internal uint GenericWrite;
            internal uint GenericExecute;
            internal uint GenericAll;
        }

        [DllImport(
            "advapi32.dll",
            EntryPoint = "GetNamedSecurityInfoW",
            CharSet = CharSet.Unicode)]
        internal static extern uint GetNamedSecurityInfo(
            string objectName,
            uint objectType,
            uint securityInfo,
            out nint owner,
            out nint group,
            out nint dacl,
            out nint sacl,
            out nint securityDescriptor);

        [DllImport(
            "advapi32.dll",
            SetLastError = true)]
        [return:
            MarshalAs(UnmanagedType.Bool)]
        internal static extern bool OpenProcessToken(
            nint processHandle,
            uint desiredAccess,
            out nint tokenHandle);

        [DllImport(
            "advapi32.dll",
            SetLastError = true)]
        [return:
            MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DuplicateToken(
            nint existingTokenHandle,
            int impersonationLevel,
            out nint duplicateTokenHandle);

        [DllImport(
            "advapi32.dll",
            SetLastError = true)]
        [return:
            MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AccessCheck(
            nint securityDescriptor,
            nint clientToken,
            uint desiredAccess,
            ref GenericMapping genericMapping,
            nint privilegeSet,
            ref uint privilegeSetLength,
            out uint grantedAccess,
            [MarshalAs(UnmanagedType.Bool)]
            out bool accessStatus);

        [DllImport("kernel32.dll")]
        [return:
            MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(
            nint handle);

        [DllImport("kernel32.dll")]
        internal static extern nint LocalFree(
            nint memory);
    }
}
