using System.Drawing;
using System.Runtime.InteropServices;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;

namespace WindowsImeCaretIndicator;

internal readonly record struct InputFocusSnapshot(nint Foreground, nint Focus, uint Thread);

internal static class FocusedInputGuard
{
    internal static bool TryCapture(out InputFocusSnapshot snapshot)
    {
        snapshot = default;
        var foreground = Native.GetForegroundWindow();
        if (foreground == nint.Zero) return false;
        var thread = Native.GetWindowThreadProcessId(foreground, out _);
        var info = new Native.GuiThreadInfo { cbSize = (uint)Marshal.SizeOf<Native.GuiThreadInfo>() };
        if (thread == 0 || !Native.GetGUIThreadInfo(thread, ref info) || info.hwndFocus == nint.Zero)
            return false;
        snapshot = new(foreground, info.hwndFocus, thread);
        return true;
    }

    internal static bool IsCurrent(InputFocusSnapshot expected) =>
        TryCapture(out var actual) && Matches(expected, actual);

    internal static bool Matches(InputFocusSnapshot expected, InputFocusSnapshot actual) =>
        expected.Foreground != nint.Zero && expected.Focus != nint.Zero &&
        expected.Foreground == actual.Foreground && expected.Focus == actual.Focus &&
        expected.Thread != 0 && expected.Thread == actual.Thread;

    internal static bool AllowsRange(object? readOnly, bool writableEdit) =>
        readOnly is false || (readOnly is not true && writableEdit);

    internal static bool AllowsCollapsedUia(string? frameworkId) =>
        !string.Equals(frameworkId, "Chrome", StringComparison.OrdinalIgnoreCase);

    internal static bool CanPresent(CaretState state)
    {
        try { return state.IsCurrent?.Invoke() == true; }
        catch (FlaUI.Core.Exceptions.ElementNotAvailableException) { return false; }
        catch (COMException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (NotSupportedException) { return false; }
    }

    internal static bool IsWritableEdit(AutomationElement focused) =>
        focused.Properties.HasKeyboardFocus.ValueOrDefault == true &&
        focused.Properties.IsEnabled.ValueOrDefault == true &&
        focused.Properties.IsOffscreen.ValueOrDefault == false &&
        focused.Properties.ControlType.TryGetValue(out var type) && type == ControlType.Edit &&
        focused.Patterns.Value.TryGetPattern(out var value) &&
        value.IsReadOnly.TryGetValue(out var readOnly) && !readOnly;

    internal static bool BelongsToForeground(AutomationElement focused, InputFocusSnapshot snapshot)
    {
        Native.GetWindowThreadProcessId(snapshot.Foreground, out var processId);
        return focused.Properties.HasKeyboardFocus.ValueOrDefault == true &&
            focused.Properties.ProcessId.ValueOrDefault == processId && IsCurrent(snapshot);
    }
}

internal static class MsaaCaretGeometry
{
    private static readonly Guid AccessibleId = new("618736e0-3c3d-11cf-810c-00aa00389b71");
    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(nint hwnd, uint objectId,
        ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out object? accessible);

    internal static bool IsUsable(int role, int state, Rectangle bounds) =>
        role == 7 && (state & (0x8000 | 0x10000)) == 0 && bounds.Height > 0 && bounds.Width > 0;

    internal static bool TryGet(InputFocusSnapshot focus, out Rectangle caret)
    {
        caret = Rectangle.Empty;
        object? instance = null;
        try
        {
            var iid = AccessibleId;
            if (AccessibleObjectFromWindow(focus.Focus, unchecked((uint)-8), ref iid, out instance) < 0 ||
                instance is not Accessibility.IAccessible accessible) return false;
            if (accessible.get_accRole(0) is not int role ||
                accessible.get_accState(0) is not int state) return false;
            accessible.accLocation(out var x, out var y, out var width, out var height, 0);
            var bounds = new Rectangle(x, y, width, height);
            if (!IsUsable(role, state, bounds) || !FocusedInputGuard.IsCurrent(focus)) return false;
            caret = new Rectangle(bounds.X, bounds.Y, 1, bounds.Height);
            return true;
        }
        catch (COMException) { return false; }
        catch (InvalidCastException) { return false; }
        finally
        {
            if (instance is not null && Marshal.IsComObject(instance)) Marshal.ReleaseComObject(instance);
        }
    }
}
