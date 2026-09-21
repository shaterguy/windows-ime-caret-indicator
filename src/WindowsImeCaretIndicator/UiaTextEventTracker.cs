using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace WindowsImeCaretIndicator;

internal sealed class UiaTextEventTracker : IDisposable
{
    private readonly Action _requestRefresh;
    private readonly AutomationEventHandler _selectionHandler;
    private readonly AutomationEventHandler _textChangedHandler;
    private bool _disposed;

    internal UiaTextEventTracker(Action requestRefresh)
    {
        _requestRefresh = requestRefresh;
        _selectionHandler = OnTextEvent;
        _textChangedHandler = OnTextEvent;

        Automation.AddAutomationEventHandler(
            TextPattern.TextSelectionChangedEvent,
            AutomationElement.RootElement,
            TreeScope.Subtree,
            _selectionHandler);

        Automation.AddAutomationEventHandler(
            TextPattern.TextChangedEvent,
            AutomationElement.RootElement,
            TreeScope.Subtree,
            _textChangedHandler);
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

        try
        {
            Automation.RemoveAutomationEventHandler(
                TextPattern.TextSelectionChangedEvent,
                AutomationElement.RootElement,
                _selectionHandler);

            Automation.RemoveAutomationEventHandler(
                TextPattern.TextChangedEvent,
                AutomationElement.RootElement,
                _textChangedHandler);
        }
        catch (InvalidOperationException)
        {
        }
    }
}
