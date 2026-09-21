using System.Text.Json;

namespace WindowsImeCaretIndicator;

internal static class ProbeOnceRunner
{
    internal static int Run()
    {
        using var caretResolver = new TextPattern2Bridge();
        var imeReader = new ImeStateReader();

        if (!caretResolver.TryGetActiveCaret(out var caret) ||
            caret is null)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                activeCaret = false,
                at = DateTimeOffset.UtcNow
            }));
            return 3;
        }

        var ime = imeReader.Read(caret);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            activeCaret = true,
            caret = new
            {
                x = caret.Caret.X,
                y = caret.Caret.Y,
                width = caret.Caret.Width,
                height = caret.Caret.Height,
                focusWindow = caret.FocusWindow.ToInt64(),
                threadId = caret.FocusThreadId,
                source = caret.Source
            },
            ime = new
            {
                mode = ime.Mode.ToString(),
                languageId = $"0x{ime.LanguageId:X4}",
                ime.Open,
                ime.Conversion,
                ime.Source
            },
            at = DateTimeOffset.UtcNow
        }));

        return 0;
    }
}
