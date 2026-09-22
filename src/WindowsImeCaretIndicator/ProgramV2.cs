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

        var probeFileIndex = Array.FindIndex(
            args,
            value => string.Equals(
                value,
                "--probe-once-file",
                StringComparison.OrdinalIgnoreCase));

        if (probeFileIndex >= 0)
        {
            if (probeFileIndex + 1 >= args.Length ||
                string.IsNullOrWhiteSpace(args[probeFileIndex + 1]))
            {
                return 5;
            }

            return ProbeOnceRunner.Run(args[probeFileIndex + 1]);
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
