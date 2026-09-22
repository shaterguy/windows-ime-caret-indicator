using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.EventHandlers;
using FlaUI.Core.Identifiers;
using FlaUI.UIA3;
using Uia3TextPattern = FlaUI.UIA3.Patterns.TextPattern;

namespace WindowsImeCaretIndicator;

internal sealed class UiaTextEventTracker : IDisposable
{
    private readonly Action _requestRefresh;
    private readonly UIA3Automation _automation = new();
    private AutomationEventHandlerBase? _selectionHandler;
    private AutomationEventHandlerBase? _textChangedHandler;
    private bool _disposed;

    internal UiaTextEventTracker(Action requestRefresh)
    {
        _requestRefresh = requestRefresh;

        try
        {
            var desktop = _automation.GetDesktop();

            _selectionHandler = desktop.RegisterAutomationEvent(
                Uia3TextPattern.TextSelectionChangedEvent,
                TreeScope.Subtree,
                OnTextEvent);

            _textChangedHandler = desktop.RegisterAutomationEvent(
                Uia3TextPattern.TextChangedEvent,
                TreeScope.Subtree,
                OnTextEvent);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    private void OnTextEvent(
        AutomationElement sender,
        EventId eventId)
    {
        if (!_disposed)
            _requestRefresh();
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;

        _selectionHandler?.Dispose();
        _selectionHandler = null;

        _textChangedHandler?.Dispose();
        _textChangedHandler = null;

        _automation.Dispose();
    }
}
