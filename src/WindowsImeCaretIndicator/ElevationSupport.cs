using System.ComponentModel;
using System.Diagnostics;
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
        if (string.IsNullOrWhiteSpace(executable))
            return false;

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
