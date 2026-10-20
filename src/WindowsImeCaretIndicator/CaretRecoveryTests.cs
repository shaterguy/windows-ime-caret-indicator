using System.Drawing;
using System.Runtime.InteropServices;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;
using FlaUI.UIA3;

namespace WindowsImeCaretIndicator;

internal static class CaretRecoveryTests
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

        Check("UIA3 unavailable element is a failed lookup", () =>
        {
            using var provider = new Uia3Text2CaretProvider(new UnavailableAutomation());
            Require(!provider.TryGetActiveCaret(out var state) && state is null);
        });
        Check("selection UIA unavailable element is a failed lookup", () =>
        {
            using var provider = new UiaCaretProvider(new UnavailableAutomation());
            Require(!provider.TryGetActiveCaret(out var state) && state is null);
        });
        Check("unavailable primary continues to selection fallback", () =>
        {
            var selection = new FixedProvider("selection");
            var win32 = new FixedProvider("win32");
            using var bridge = new TextPattern2Bridge(
                new Uia3Text2CaretProvider(new UnavailableAutomation()), selection, win32);
            Require(bridge.TryGetActiveCaret(out var state) && state?.Source == "selection");
            Require(selection.Calls == 1 && win32.Calls == 0);
        });
        Check("unavailable UIA providers preserve subsequent timer refresh", () =>
        {
            var fallback = new FixedProvider("win32");
            using var bridge = new TextPattern2Bridge(
                new Uia3Text2CaretProvider(new UnavailableAutomation()),
                new UiaCaretProvider(new UnavailableAutomation()), fallback);
            using var context = new System.Windows.Forms.ApplicationContext();
            using var timer = new System.Windows.Forms.Timer { Interval = 10 };
            using var watchdog = new System.Windows.Forms.Timer { Interval = 5000 };
            var ticks = 0;
            Exception? failure = null;
            timer.Tick += (_, _) =>
            {
                try
                {
                    Require(bridge.TryGetActiveCaret(out var state) && state?.Source == "win32");
                    ticks++;
                    if (ticks == 2) context.ExitThread();
                }
                catch (Exception ex) { failure = ex; context.ExitThread(); }
            };
            watchdog.Tick += (_, _) => context.ExitThread();
            timer.Start();
            watchdog.Start();
            Application.Run(context);
            timer.Stop();
            watchdog.Stop();
            if (failure is not null) throw failure;
            Require(ticks == 2 && fallback.Calls == 2);
        });
        Check("unrelated provider exception is not swallowed", () =>
        {
            using var primary = new Uia3Text2CaretProvider(new BrokenAutomation());
            using var selection = new UiaCaretProvider(new BrokenAutomation());
            foreach (ICaretProvider provider in new ICaretProvider[] { primary, selection })
            {
                try { provider.TryGetActiveCaret(out _); }
                catch (ApplicationException) { continue; }
                throw new InvalidOperationException("Unrelated exception was swallowed.");
            }
        });
        return count;
    }

    private static void Require(bool condition)
    {
        if (!condition) throw new InvalidOperationException("Caret recovery assertion failed.");
    }

    private sealed class UnavailableAutomation : UIA3Automation
    {
        private bool _first = true;
        public override AutomationElement FocusedElement()
        {
            if (!_first) return null!;
            _first = false;
            // Use FlaUI's actual HRESULT conversion, not a synthetic replacement type.
            return FlaUI.Core.Tools.Com.Call<AutomationElement>(() =>
                throw new COMException("Test element disappeared", unchecked((int)0x80040201)));
        }
    }

    private sealed class BrokenAutomation : UIA3Automation
    {
        public override AutomationElement FocusedElement() =>
            throw new ApplicationException("Unrelated test failure");
    }

    private sealed class FixedProvider(string source) : ICaretProvider
    {
        internal int Calls { get; private set; }
        public bool TryGetActiveCaret(out CaretState? state)
        {
            Calls++;
            state = new CaretState(new Rectangle(1, 1, 1, 20), nint.Zero, 0, source);
            return true;
        }
    }
}
