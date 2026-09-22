using System.Drawing;

namespace WindowsImeCaretIndicator;

internal enum ImeMode
{
    Unknown,
    English,
    Korean
}

internal sealed record ImeReading(
    ImeMode Mode,
    ushort LanguageId,
    bool? Open,
    int? Conversion,
    string Source);

internal sealed record CaretState(
    Rectangle Caret,
    nint FocusWindow,
    uint FocusThreadId,
    string Source);

internal static class ImeLogic
{
    internal const ushort KoreanLanguageId = 0x0412;
    internal const int NativeMode = 0x0001;

    internal static ImeMode Normalize(ushort languageId, bool? open, int? conversion)
    {
        if (languageId != KoreanLanguageId)
            return ImeMode.English;

        if (open is false)
            return ImeMode.English;

        if (open is not true || conversion is null)
            return ImeMode.Unknown;

        return (conversion.Value & NativeMode) != 0
            ? ImeMode.Korean
            : ImeMode.English;
    }
}

internal static class OverlayMetrics
{
    internal static Size CalculateSize(Rectangle caret, uint dpi)
    {
        var scale = Math.Max(1.0, dpi / 96.0);
        var min = 12.0 * scale;
        var max = 20.0 * scale;
        var desired = Math.Max(1, caret.Height) * 0.65;
        var side = (int)Math.Round(Math.Clamp(desired, min, max));
        return new Size(side, side);
    }

    internal static (int X, int Y) CalculateGap(uint dpi)
    {
        var scale = Math.Max(1.0, dpi / 96.0);
        return ((int)Math.Round(4 * scale), (int)Math.Round(2 * scale));
    }
}

internal static class OverlayPlacement
{
    internal static Rectangle Choose(Rectangle caret, Size overlay, Rectangle workArea, int gapX, int gapY)
    {
        var points = new[]
        {
            new Point(caret.Right + gapX, caret.Bottom + gapY),
            new Point(caret.Left - overlay.Width - gapX, caret.Bottom + gapY),
            new Point(caret.Right + gapX, caret.Top - overlay.Height - gapY),
            new Point(caret.Left - overlay.Width - gapX, caret.Top - overlay.Height - gapY)
        };

        foreach (var point in points)
        {
            var candidate = new Rectangle(point, overlay);
            if (workArea.Contains(candidate))
                return candidate;
        }

        return new Rectangle(
            Math.Clamp(caret.Right + gapX, workArea.Left, Math.Max(workArea.Left, workArea.Right - overlay.Width)),
            Math.Clamp(caret.Bottom + gapY, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - overlay.Height)),
            overlay.Width,
            overlay.Height);
    }
}

internal static class SelfTests
{
    internal static int Run()
    {
        var errors = new List<string>();

        Check("non-Korean layout is English", () =>
            Equal(ImeMode.English, ImeLogic.Normalize(0x0409, null, null)), errors);
        Check("closed Korean IME is English", () =>
            Equal(ImeMode.English, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, false, ImeLogic.NativeMode)), errors);
        Check("native Korean IME is Korean", () =>
            Equal(ImeMode.Korean, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, true, ImeLogic.NativeMode)), errors);
        Check("alphanumeric Korean IME is English", () =>
            Equal(ImeMode.English, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, true, 0)), errors);
        Check("unknown Korean conversion stays unknown", () =>
            Equal(ImeMode.Unknown, ImeLogic.Normalize(ImeLogic.KoreanLanguageId, true, null)), errors);

        Check("lower-right placement", () =>
            Equal(
                new Rectangle(105, 122, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(100, 100, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("right-edge flips left", () =>
            Equal(
                new Rectangle(1895, 122, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(1915, 100, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("left-edge stays inside to the right", () =>
            Equal(
                new Rectangle(5, 122, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(0, 100, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("top-edge stays inside below", () =>
            Equal(
                new Rectangle(105, 22, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(100, 0, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("top-left corner stays lower-right", () =>
            Equal(
                new Rectangle(5, 22, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(0, 0, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("top-right corner flips lower-left", () =>
            Equal(
                new Rectangle(1895, 22, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(1915, 0, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("negative-coordinate monitor remains in work area", () =>
        {
            var workArea = new Rectangle(-1920, 0, 1920, 1080);
            var result = OverlayPlacement.Choose(
                new Rectangle(-20, 1000, 1, 20),
                new Size(16, 16),
                workArea,
                4,
                2);
            if (!workArea.Contains(result))
                throw new InvalidOperationException(result.ToString());
        }, errors);

        Check("100 percent DPI size follows caret height", () =>
            Equal(new Size(13, 13), OverlayMetrics.CalculateSize(new Rectangle(0, 0, 1, 20), 96)), errors);

        Check("125 percent DPI minimum scales", () =>
            Equal(new Size(15, 15), OverlayMetrics.CalculateSize(new Rectangle(0, 0, 1, 20), 120)), errors);

        Check("150 percent DPI minimum scales", () =>
            Equal(new Size(18, 18), OverlayMetrics.CalculateSize(new Rectangle(0, 0, 1, 20), 144)), errors);

        Check("200 percent DPI minimum scales", () =>
            Equal(new Size(24, 24), OverlayMetrics.CalculateSize(new Rectangle(0, 0, 1, 20), 192)), errors);

        Check("bottom edge flips above", () =>
            Equal(
                new Rectangle(105, 1042, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(100, 1060, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("bottom-right corner flips upper-left", () =>
            Equal(
                new Rectangle(1895, 1042, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(1915, 1060, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("bottom-left corner flips upper-right", () =>
            Equal(
                new Rectangle(5, 1042, 16, 16),
                OverlayPlacement.Choose(
                    new Rectangle(0, 1060, 1, 20),
                    new Size(16, 16),
                    new Rectangle(0, 0, 1920, 1080),
                    4,
                    2)),
            errors);

        Check("elevation restart requires explicit runas consent", () =>
        {
            var info = ElevationSupport.CreateRestartStartInfo(
                @"C:\Program Files\WICI\WindowsImeCaretIndicator.exe");
            Equal("runas", info.Verb);
            Equal(true, info.UseShellExecute);
            Equal("--wait-for-instance", info.Arguments);
        }, errors);

        Check("protected elevation policy accepts exact trusted target", () =>
            Equal(
                true,
                ElevationTargetPolicy.IsAccepted(
                    exactTarget: true,
                    targetExists: true,
                    hasReparsePoint: false,
                    currentUserHasUnsafeAccess: false,
                    validationSucceeded: true)),
            errors);

        Check("protected elevation policy rejects wrong target", () =>
            Equal(
                false,
                ElevationTargetPolicy.IsAccepted(
                    exactTarget: false,
                    targetExists: true,
                    hasReparsePoint: false,
                    currentUserHasUnsafeAccess: false,
                    validationSucceeded: true)),
            errors);

        Check("protected elevation policy rejects reparse target", () =>
            Equal(
                false,
                ElevationTargetPolicy.IsAccepted(
                    exactTarget: true,
                    targetExists: true,
                    hasReparsePoint: true,
                    currentUserHasUnsafeAccess: false,
                    validationSucceeded: true)),
            errors);

        Check("protected elevation policy rejects writable target", () =>
            Equal(
                false,
                ElevationTargetPolicy.IsAccepted(
                    exactTarget: true,
                    targetExists: true,
                    hasReparsePoint: false,
                    currentUserHasUnsafeAccess: true,
                    validationSucceeded: true)),
            errors);

        Check("protected elevation policy fails closed on validation error", () =>
            Equal(
                false,
                ElevationTargetPolicy.IsAccepted(
                    exactTarget: true,
                    targetExists: true,
                    hasReparsePoint: false,
                    currentUserHasUnsafeAccess: false,
                    validationSucceeded: false)),
            errors);

        Check("migration preserves existing v2 state", () =>
        {
            var selected = LegacyV010Lifecycle.ChooseSettings(
                new AppSettings
                {
                    StartWithWindows = false,
                    Paused = true,
                    InstallExecutablePath = @"C:\Program Files\WICI\current.exe"
                },
                new AppSettings
                {
                    StartWithWindows = true,
                    Paused = false
                },
                legacyStartupOwned: true);

            Equal(false, selected.StartWithWindows);
            Equal(true, selected.Paused);
            Equal(
                @"C:\Program Files\WICI\current.exe",
                selected.InstallExecutablePath!);
        }, errors);

        Check("migration preserves formal v0.1.0 settings", () =>
        {
            var selected = LegacyV010Lifecycle.ChooseSettings(
                current: null,
                legacy: new AppSettings
                {
                    StartWithWindows = false,
                    Paused = true
                },
                legacyStartupOwned: true);

            Equal(false, selected.StartWithWindows);
            Equal(true, selected.Paused);
        }, errors);

        Check("migration infers startup from owned legacy Run value", () =>
        {
            var selected = LegacyV010Lifecycle.ChooseSettings(
                current: null,
                legacy: null,
                legacyStartupOwned: true);

            Equal(true, selected.StartWithWindows);
            Equal(false, selected.Paused);
        }, errors);

        Check("single instance lease excludes a second thread", () =>
        {
            var name = @"Local\WiciSelfTest-" + Guid.NewGuid().ToString("N");
            using var first = SingleInstanceLease.TryAcquire(
                name,
                TimeSpan.Zero)
                ?? throw new InvalidOperationException(
                    "first lease was not acquired");

            var secondAcquired = Task.Run(() =>
            {
                using var second = SingleInstanceLease.TryAcquire(
                    name,
                    TimeSpan.Zero);
                return second is not null;
            }).GetAwaiter().GetResult();

            if (secondAcquired)
                throw new InvalidOperationException(
                    "second thread acquired the owned mutex");
        }, errors);

        foreach (var error in errors)
            Console.Error.WriteLine(error);

        const int total = 29;
        Console.WriteLine($"{total - errors.Count}/{total} tests passed.");
        return errors.Count == 0 ? 0 : 1;
    }

    private static void Check(string name, Action action, ICollection<string> errors)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            errors.Add($"FAIL {name}: {ex.Message}");
        }
    }

    private static void Equal<T>(T expected, T actual) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"expected {expected}, actual {actual}");
    }
}
