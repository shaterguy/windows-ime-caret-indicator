using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace WindowsImeCaretIndicator;

internal static class ProbeOnceRunner
{
    private const uint TokenQuery = 0x0008;
    private const int TokenIntegrityLevel = 25;

    [StructLayout(LayoutKind.Sequential)]
    private struct SidAndAttributes
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenMandatoryLabel
    {
        public SidAndAttributes Label;
    }

    private sealed record ProcessSecuritySnapshot(
        int Id,
        int IntegrityRid,
        string IntegrityName);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint subAuthority);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    internal static int Run()
    {
        var process = ReadCurrentProcessSecurity();

        try
        {
            using var caretResolver = new TextPattern2Bridge();
            var imeReader = new ImeStateReader();

            if (!caretResolver.TryGetActiveCaret(out var caret) ||
                caret is null)
            {
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    activeCaret = false,
                    process,
                    at = DateTimeOffset.UtcNow
                }));
                return 3;
            }

            var ime = imeReader.Read(caret);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                activeCaret = true,
                process,
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
        catch (Exception ex)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                activeCaret = false,
                process,
                error = new
                {
                    type = ex.GetType().FullName,
                    hResult = $"0x{ex.HResult:X8}",
                    ex.Message
                },
                at = DateTimeOffset.UtcNow
            }));
            return 4;
        }
    }

    private static ProcessSecuritySnapshot ReadCurrentProcessSecurity()
    {
        try
        {
            using var current = Process.GetCurrentProcess();
            if (!OpenProcessToken(
                    current.Handle,
                    TokenQuery,
                    out var token))
            {
                return new(
                    Environment.ProcessId,
                    -1,
                    "Unknown");
            }

            try
            {
                _ = GetTokenInformation(
                    token,
                    TokenIntegrityLevel,
                    IntPtr.Zero,
                    0,
                    out var requiredLength);
                if (requiredLength <= 0)
                {
                    return new(
                        Environment.ProcessId,
                        -1,
                        "Unknown");
                }

                var buffer = Marshal.AllocHGlobal(requiredLength);
                try
                {
                    if (!GetTokenInformation(
                            token,
                            TokenIntegrityLevel,
                            buffer,
                            requiredLength,
                            out _))
                    {
                        return new(
                            Environment.ProcessId,
                            -1,
                            "Unknown");
                    }

                    var label =
                        Marshal.PtrToStructure<TokenMandatoryLabel>(
                            buffer);
                    if (label.Label.Sid == IntPtr.Zero)
                    {
                        return new(
                            Environment.ProcessId,
                            -1,
                            "Unknown");
                    }

                    var countPointer =
                        GetSidSubAuthorityCount(label.Label.Sid);
                    if (countPointer == IntPtr.Zero)
                    {
                        return new(
                            Environment.ProcessId,
                            -1,
                            "Unknown");
                    }

                    var count = Marshal.ReadByte(countPointer);
                    if (count == 0)
                    {
                        return new(
                            Environment.ProcessId,
                            -1,
                            "Unknown");
                    }

                    var ridPointer = GetSidSubAuthority(
                        label.Label.Sid,
                        (uint)(count - 1));
                    var rid = ridPointer == IntPtr.Zero
                        ? -1
                        : Marshal.ReadInt32(ridPointer);

                    return new(
                        Environment.ProcessId,
                        rid,
                        IntegrityName(rid));
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                _ = CloseHandle(token);
            }
        }
        catch
        {
            return new(
                Environment.ProcessId,
                -1,
                "Unknown");
        }
    }

    private static string IntegrityName(int rid) =>
        rid switch
        {
            < 0 => "Unknown",
            < 0x2000 => "Low",
            < 0x3000 => "Medium",
            < 0x4000 => "High",
            < 0x5000 => "System",
            _ => "Protected"
        };
}
