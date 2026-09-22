namespace WindowsImeCaretIndicator;

internal sealed class TextPattern2Bridge : IDisposable
{
    private readonly Uia3Text2CaretProvider _primary = new();
    private readonly UiaCaretProvider _selectionFallback = new();
    private readonly Win32CaretProvider _fallback = new();

    internal bool TryGetActiveCaret(out CaretState? state)
    {
        if (_primary.TryGetActiveCaret(out state) && state is not null)
            return true;

        if (_selectionFallback.TryGetActiveCaret(out state) && state is not null)
            return true;

        return _fallback.TryGetActiveCaret(out state);
    }

    public void Dispose()
    {
        _selectionFallback.Dispose();
        _primary.Dispose();
    }
}
