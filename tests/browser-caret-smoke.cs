#:property PublishAot=false
#:property PublishTrimmed=false
#:property JsonSerializerIsReflectionEnabledByDefault=true

using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Runtime.InteropServices;
using System.Text.Json;

if (args.Length != 1)
    throw new ArgumentException("Expected the WindowsImeCaretIndicator executable path.");

var executablePath = Path.GetFullPath(args[0]);
if (!File.Exists(executablePath))
    throw new FileNotFoundException("Probe executable was not found.", executablePath);

await TestBrowserAsync(
    displayName: "chrome",
    driverEnvironmentVariable: "CHROMEWEBDRIVER",
    driverFileName: "chromedriver.exe",
    browserName: "chrome",
    browserProcessName: "chrome",
    optionsKey: "goog:chromeOptions",
    port: 9515,
    executablePath);

await TestBrowserAsync(
    displayName: "MicrosoftEdge",
    driverEnvironmentVariable: "EDGEWEBDRIVER",
    driverFileName: "msedgedriver.exe",
    browserName: "MicrosoftEdge",
    browserProcessName: "msedge",
    optionsKey: "ms:edgeOptions",
    port: 9516,
    executablePath);

return;

static async Task TestBrowserAsync(
    string displayName,
    string driverEnvironmentVariable,
    string driverFileName,
    string browserName,
    string browserProcessName,
    string optionsKey,
    int port,
    string executablePath)
{
    var driverRoot = Environment.GetEnvironmentVariable(driverEnvironmentVariable);
    if (string.IsNullOrWhiteSpace(driverRoot))
        throw new InvalidOperationException($"{driverEnvironmentVariable} is not available.");

    var driverPath = Directory.Exists(driverRoot)
        ? Path.Combine(driverRoot, driverFileName)
        : driverRoot;

    if (!File.Exists(driverPath))
        throw new FileNotFoundException($"{displayName} WebDriver was not found.", driverPath);

    using var driver = StartDriver(driverPath, port);
    using var client = new HttpClient
    {
        BaseAddress = new Uri($"http://127.0.0.1:{port}/"),
        Timeout = TimeSpan.FromSeconds(10),
        DefaultRequestVersion = HttpVersion.Version11,
        DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact
    };
    client.DefaultRequestHeaders.ConnectionClose = true;

    string? sessionId = null;

    try
    {
        await WaitForDriverAsync(client);

        var alwaysMatch = new Dictionary<string, object?>
        {
            ["browserName"] = browserName,
            [optionsKey] = new Dictionary<string, object?>
            {
                ["args"] = new[]
                {
                    "--force-renderer-accessibility",
                    "--no-first-run",
                    "--disable-search-engine-choice-screen",
                    "--disable-features=TranslateUI",
                    "--window-size=1000,700"
                }
            }
        };

        var session = await SendJsonAsync(
            client,
            HttpMethod.Post,
            "session",
            new
            {
                capabilities = new
                {
                    alwaysMatch
                }
            });

        sessionId = session.GetProperty("value").GetProperty("sessionId").GetString();
        if (string.IsNullOrWhiteSpace(sessionId))
            throw new InvalidOperationException($"{displayName} WebDriver did not return a session id.");

        const string html = """
<!doctype html>
<meta charset="utf-8">
<title>WICI browser caret test</title>
<style>
body { font: 24px Segoe UI; padding: 60px; }
input, textarea, [contenteditable] { display: block; width: 720px; margin: 24px 0; font: 24px Consolas; }
textarea { height: 160px; }
[contenteditable] { min-height: 80px; border: 1px solid #888; padding: 4px; }
</style>
<input id="probe-input" value="abc">
<textarea id="probe-textarea">abc</textarea>
<div id="probe-contenteditable" contenteditable="true">abc</div>
""";

        var url = "data:text/html;charset=utf-8," + Uri.EscapeDataString(html);
        _ = await SendJsonAsync(
            client,
            HttpMethod.Post,
            $"session/{sessionId}/url",
            new { url });

        await FocusBrowserWindowAsync(browserProcessName);

        foreach (var target in new[]
        {
            new BrowserTarget("probe-input", "input"),
            new BrowserTarget("probe-textarea", "textarea"),
            new BrowserTarget("probe-contenteditable", "contenteditable")
        })
        {
            var focusResult = await SendJsonAsync(
                client,
                HttpMethod.Post,
                $"session/{sessionId}/execute/sync",
                new
                {
                    script = """
const el = document.getElementById(arguments[0]);
el.focus();
if (el.isContentEditable) {
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
} else {
    el.setSelectionRange(2, 2);
}
return document.activeElement === el;
""",
                    args = new object[] { target.Id }
                });

            if (!focusResult.GetProperty("value").GetBoolean())
                throw new InvalidOperationException($"{displayName} did not focus the test {target.Label}.");

            await Task.Delay(300);

            var probe = await RunProbeAsync(executablePath);
            if (!probe.ActiveCaret)
                throw new InvalidOperationException($"{displayName} {target.Label} did not report an active caret.");

            if (probe.Source is not ("UIA3.TextPattern2.GetCaretRange" or "UIA.TextPattern.Selection"))
                throw new InvalidOperationException($"{displayName} {target.Label} used unsupported caret source '{probe.Source}'.");

            if (probe.Height <= 0)
                throw new InvalidOperationException($"{displayName} {target.Label} returned invalid caret height {probe.Height}.");

            if (string.Equals(probe.ImeMode, "Unknown", StringComparison.Ordinal))
                throw new InvalidOperationException($"{displayName} {target.Label} IME mode could not be resolved.");

            Console.WriteLine(
                $"{displayName} {target.Label} caret probe passed: source={probe.Source}, mode={probe.ImeMode}, height={probe.Height}");
        }
    }
    finally
    {
        if (!string.IsNullOrWhiteSpace(sessionId))
        {
            try
            {
                _ = await SendJsonAsync(client, HttpMethod.Delete, $"session/{sessionId}", body: null);
            }
            catch
            {
            }
        }

        if (!driver.HasExited)
        {
            try
            {
                driver.Kill(entireProcessTree: true);
            }
            catch
            {
            }
        }
    }
}

static Process StartDriver(string driverPath, int port)
{
    var startInfo = new ProcessStartInfo
    {
        FileName = driverPath,
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
    };

    startInfo.ArgumentList.Add($"--port={port}");
    startInfo.ArgumentList.Add("--silent");

    return Process.Start(startInfo)
        ?? throw new InvalidOperationException($"Unable to start WebDriver '{driverPath}'.");
}

static async Task WaitForDriverAsync(HttpClient client)
{
    for (var attempt = 0; attempt < 40; attempt++)
    {
        try
        {
            using var response = await client.GetAsync("status");
            if (response.IsSuccessStatusCode)
                return;
        }
        catch (HttpRequestException)
        {
        }
        catch (TaskCanceledException)
        {
        }

        await Task.Delay(100);
    }

    throw new TimeoutException("WebDriver did not become ready.");
}

static async Task<JsonElement> SendJsonAsync(
    HttpClient client,
    HttpMethod method,
    string path,
    object? body)
{
    using var request = new HttpRequestMessage(method, path);
    if (body is not null)
        request.Content = JsonContent.Create(body);

    using var response = await client.SendAsync(request);
    var responseText = await response.Content.ReadAsStringAsync();

    if (!response.IsSuccessStatusCode)
        throw new InvalidOperationException(
            $"WebDriver request {method} {path} failed with {(int)response.StatusCode}: {responseText}");

    if (string.IsNullOrWhiteSpace(responseText))
        return JsonDocument.Parse("{}").RootElement.Clone();

    using var document = JsonDocument.Parse(responseText);
    return document.RootElement.Clone();
}

static async Task FocusBrowserWindowAsync(string processName)
{
    for (var attempt = 0; attempt < 40; attempt++)
    {
        foreach (var process in Process.GetProcessesByName(processName))
        {
            using (process)
            {
                if (process.MainWindowHandle != IntPtr.Zero &&
                    NativeMethods.SetForegroundWindow(process.MainWindowHandle))
                {
                    await Task.Delay(100);
                    return;
                }
            }
        }

        await Task.Delay(100);
    }

    throw new InvalidOperationException($"Unable to foreground browser process '{processName}'.");
}

static async Task<ProbeResult> RunProbeAsync(string executablePath)
{
    var startInfo = new ProcessStartInfo
    {
        FileName = executablePath,
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
    };
    startInfo.ArgumentList.Add("--probe-once");

    using var process = Process.Start(startInfo)
        ?? throw new InvalidOperationException("Unable to start the caret probe.");

    var stdoutTask = process.StandardOutput.ReadToEndAsync();
    var stderrTask = process.StandardError.ReadToEndAsync();

    await process.WaitForExitAsync();
    var stdout = await stdoutTask;
    var stderr = await stderrTask;

    if (process.ExitCode != 0)
        throw new InvalidOperationException(
            $"Caret probe exited with code {process.ExitCode}. stdout={stdout} stderr={stderr}");

    var jsonLine = stdout
        .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
        .LastOrDefault();

    if (string.IsNullOrWhiteSpace(jsonLine))
        throw new InvalidOperationException("Caret probe produced no JSON output.");

    using var document = JsonDocument.Parse(jsonLine);
    var root = document.RootElement;

    var activeCaret = root.TryGetProperty("activeCaret", out var activeElement) &&
                      activeElement.GetBoolean();

    if (!activeCaret)
        return new ProbeResult(false, string.Empty, 0, "Unknown");

    var caret = root.GetProperty("caret");
    var ime = root.GetProperty("ime");

    return new ProbeResult(
        true,
        caret.GetProperty("source").GetString() ?? string.Empty,
        caret.GetProperty("height").GetInt32(),
        ime.GetProperty("mode").GetString() ?? "Unknown");
}

internal sealed record BrowserTarget(string Id, string Label);

internal sealed record ProbeResult(
    bool ActiveCaret,
    string Source,
    int Height,
    string ImeMode);

internal static class NativeMethods
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(IntPtr hWnd);
}
