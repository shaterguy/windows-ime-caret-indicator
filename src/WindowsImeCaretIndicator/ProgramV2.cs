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

        using var singleInstance = new Mutex(
            initiallyOwned: true,
            name: @"Local\WindowsImeCaretIndicator",
            createdNew: out var createdNew);

        if (!createdNew)
            return 0;

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new IndicatorApplicationContextV2());

        return 0;
    }
}
