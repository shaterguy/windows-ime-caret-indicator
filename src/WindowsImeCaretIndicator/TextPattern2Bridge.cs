namespace WindowsImeCaretIndicator;

internal sealed class TextPattern2Bridge : IDisposable
{
    private readonly ICaretProvider _primary;
    private readonly ICaretProvider _selectionFallback;
    private readonly ICaretProvider _fallback;

    internal TextPattern2Bridge(
        ICaretProvider? primary = null,
        ICaretProvider? selectionFallback = null,
        ICaretProvider? fallback = null)
    {
        _primary = primary ?? new Uia3Text2CaretProvider();
        _selectionFallback = selectionFallback ?? new UiaCaretProvider();
        _fallback = fallback ?? new Win32CaretProvider();
    }

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
        (_selectionFallback as IDisposable)?.Dispose();
        (_primary as IDisposable)?.Dispose();
    }
}
