using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace WindowsImeCaretIndicator;

internal sealed class UiaTextEventTracker : IDisposable
{
    private readonly Action _requestRefresh;
    private readonly AutomationEventHandler _selectionHandler;
    private readonly AutomationEventHandler _textChangedHandler;
    private bool _selectionRegistered;
    private bool _textChangedRegistered;
    private bool _disposed;

    internal UiaTextEventTracker(Action requestRefresh)
    {
        _requestRefresh = requestRefresh;
        _selectionHandler = OnTextEvent;
        _textChangedHandler = OnTextEvent;

        try
        {
            Automation.AddAutomationEventHandler(
                TextPattern.TextSelectionChangedEvent,
                AutomationElement.RootElement,
                TreeScope.Subtree,
                _selectionHandler);
            _selectionRegistered = true;

            Automation.AddAutomationEventHandler(
                TextPattern.TextChangedEvent,
                AutomationElement.RootElement,
                TreeScope.Subtree,
                _textChangedHandler);
            _textChangedRegistered = true;
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    private void OnTextEvent(object sender, AutomationEventArgs e)
    {
        if (!_disposed)
            _requestRefresh();
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;

        if (_selectionRegistered)
        {
            TryRemove(
                TextPattern.TextSelectionChangedEvent,
                _selectionHandler);
            _selectionRegistered = false;
        }

        if (_textChangedRegistered)
        {
            TryRemove(
                TextPattern.TextChangedEvent,
                _textChangedHandler);
            _textChangedRegistered = false;
        }
    }

    private static void TryRemove(
        AutomationEvent eventId,
        AutomationEventHandler handler)
    {
        try
        {
            Automation.RemoveAutomationEventHandler(
                eventId,
                AutomationElement.RootElement,
                handler);
        }
        catch (InvalidOperationException)
        {
        }
    }
}
