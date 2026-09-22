using System.Windows.Forms;

namespace WindowsImeCaretIndicator;

internal static class ProgramV2
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine(
                "Windows IME Caret Indicator requires Windows.");
            return 2;
        }

        _ = Native.SetProcessDpiAwarenessContext(new nint(-4));

        if (args.Contains(
                "--self-test",
                StringComparer.OrdinalIgnoreCase))
        {
            return SelfTests.Run();
        }

        if (args.Contains(
                "--test-host-korean",
                StringComparer.OrdinalIgnoreCase))
        {
            return NativeTestHost.Run(activateKorean: true);
        }

        if (args.Contains(
                "--test-host",
                StringComparer.OrdinalIgnoreCase))
        {
            return NativeTestHost.Run();
        }

        if (args.Contains(
                "--probe-once",
                StringComparer.OrdinalIgnoreCase))
        {
            return ProbeOnceRunner.Run();
        }

        if (args.Contains(
                "--diagnose",
                StringComparer.OrdinalIgnoreCase))
        {
            return DiagnosticRunner.Run();
        }

        if (args.Contains(
                "--verify-protected-install",
                StringComparer.OrdinalIgnoreCase))
        {
            var executable = Environment.ProcessPath;
            return !string.IsNullOrWhiteSpace(executable) &&
                   ElevationSupport.IsProtectedElevationTarget(executable)
                ? 0
                : 5;
        }

        if (args.Contains(
                "--migrate-v0.1.0",
                StringComparer.OrdinalIgnoreCase))
        {
            return LegacyV010Lifecycle.MigrateCurrentUserBestEffort()
                ? 0
                : 6;
        }

        if (args.Contains(
                "--uninstall-current-user",
                StringComparer.OrdinalIgnoreCase))
        {
            return LegacyV010Lifecycle.CleanupCurrentUserForUninstallBestEffort()
                ? 0
                : 7;
        }

        _ = LegacyV010Lifecycle.MigrateCurrentUserBestEffort();

        var waitForInstance = args.Contains(
            "--wait-for-instance",
            StringComparer.OrdinalIgnoreCase);

        using var singleInstance = SingleInstanceLease.TryAcquire(
            @"Local\WindowsImeCaretIndicator",
            waitForInstance
                ? TimeSpan.FromSeconds(15)
                : TimeSpan.Zero);

        if (singleInstance is null)
            return 0;

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new IndicatorApplicationContextV2());

        return 0;
    }
}
