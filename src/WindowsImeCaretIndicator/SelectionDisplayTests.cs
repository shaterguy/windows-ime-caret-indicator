using System.Drawing;
using System.Reflection;
using FlaUI.Core.Definitions;
using FlaUI.Core.Patterns;

namespace WindowsImeCaretIndicator;

internal static class SelectionDisplayTests
{
    internal static int Run(ICollection<string> errors)
    {
        var count = 0;
        void Check(string name, Action action)
        {
            count++;
            try { action(); }
            catch (Exception ex) { errors.Add($"FAIL: {name}: {ex}"); }
        }
        Check("selected edit anchors actual block without altering selection", () =>
        {
            var range = SimulatedTextRangeProxy.Create(0, 5, true);
            Require(UiaCaretProvider.TryGetSelectionRectangle(range, true, out var caret));
            Require(caret.X == 150 && caret.Height == 20);
            Require(((SimulatedTextRangeProxy)(object)range).Start == 0);
        });
        Check("collapsed caret preserves provider geometry", () =>
        {
            var range = SimulatedTextRangeProxy.Create(2, 2, true);
            Require(UiaCaretProvider.TryGetSelectionRectangle(range, false, out var caret) && caret.X == 120);
        });
        Check("empty unavailable geometry never invents field origin", () =>
        {
            var range = SimulatedTextRangeProxy.Create(0, 0, false);
            Require(!UiaCaretProvider.TryGetSelectionRectangle(range, false, out _));
        });
        Check("selection anchor uses selected range only as fallback", () =>
        {
            var range = SimulatedTextRangeProxy.Create(0, 5, false);
            Require(UiaCaretProvider.TryGetSelectionRectangle(range, true, out var caret) && caret.X == 150);
        });
        Check("foreground focus snapshot rejects window switch", () =>
            Require(!FocusedInputGuard.Matches(new(1, 2, 3), new(4, 2, 3))));
        Check("foreground focus snapshot rejects focus loss", () =>
            Require(!FocusedInputGuard.Matches(new(1, 2, 3), new(1, 0, 3))));
        Check("foreground focus snapshot retains same logical focus", () =>
            Require(FocusedInputGuard.Matches(new(1, 2, 3), new(1, 2, 3))));
        Check("MSAA rejects invisible and offscreen stale caret", () =>
        {
            Require(!MsaaCaretGeometry.IsUsable(7, 0x8000, new(10, 20, 1, 20)));
            Require(!MsaaCaretGeometry.IsUsable(7, 0x10000, new(10, 20, 1, 20)));
        });
        Check("MSAA logical caret independent of visual blink", () =>
            Require(MsaaCaretGeometry.IsUsable(7, 0, new(10, 20, 1, 20))));
        Check("MSAA rejects noncaret and empty geometry", () =>
        {
            Require(!MsaaCaretGeometry.IsUsable(42, 0, new(10, 20, 1, 20)));
            Require(!MsaaCaretGeometry.IsUsable(7, 0, Rectangle.Empty));
        });
        Check("explicit readonly span overrides writable edit", () =>
            Require(!FocusedInputGuard.AllowsRange(true, true)));
        Check("writable range and supported edit allow real geometry", () =>
        {
            Require(FocusedInputGuard.AllowsRange(false, false));
            Require(FocusedInputGuard.AllowsRange(null, true));
            Require(!FocusedInputGuard.AllowsRange(null, false));
        });
        Check("Chrome collapsed fallback cannot invent a field origin", () =>
        {
            Require(!FocusedInputGuard.AllowsCollapsedUia("Chrome"));
            Require(FocusedInputGuard.AllowsCollapsedUia("WinForm"));
        });
        Check("focus invalidation before presentation rejects stale caret", () =>
        {
            var active = true;
            var state = new CaretState(new(1, 2, 1, 20), 1, 2, "test", () => active);
            Require(FocusedInputGuard.CanPresent(state));
            active = false;
            Require(!FocusedInputGuard.CanPresent(state));
        });
        Check("unverified or unavailable presentation anchor stays hidden", () =>
        {
            Require(!FocusedInputGuard.CanPresent(new(new(1, 2, 1, 20), 1, 2, "test")));
            Require(!FocusedInputGuard.CanPresent(new(new(1, 2, 1, 20), 1, 2, "test",
                () => throw new FlaUI.Core.Exceptions.ElementNotAvailableException())));
        });
        return count;
    }
    private static void Require(bool ok) { if (!ok) throw new InvalidOperationException("Assertion failed."); }
}

public class SimulatedTextRangeProxy : DispatchProxy
{
    internal int Start;
    internal int End;
    private bool _hasCaretBounds;
    internal static ITextRange Create(int start, int end, bool hasCaretBounds)
    {
        var range = DispatchProxy.Create<ITextRange, SimulatedTextRangeProxy>();
        var proxy = (SimulatedTextRangeProxy)(object)range;
        proxy.Start = start; proxy.End = end; proxy._hasCaretBounds = hasCaretBounds;
        return range;
    }
    protected override object? Invoke(MethodInfo? method, object?[]? args)
    {
        switch (method?.Name)
        {
            case "Clone": return Create(Start, End, _hasCaretBounds);
            case "GetBoundingRectangles":
                if (Start == End && !_hasCaretBounds) return Array.Empty<Rectangle>();
                return new[] { new Rectangle(100 + Start * 10, 50, Math.Max(1, (End - Start) * 10), 20) };
            case "MoveEndpointByRange":
                var other = (SimulatedTextRangeProxy)args![1]!;
                var position = (TextPatternRangeEndpoint)args[2]! == TextPatternRangeEndpoint.Start ? other.Start : other.End;
                if ((TextPatternRangeEndpoint)args[0]! == TextPatternRangeEndpoint.Start) Start = position; else End = position;
                return null;
            case "MoveEndpointByUnit": return 0;
            default: throw new NotSupportedException(method?.Name);
        }
    }
}
