using Microsoft.Web.WebView2.WinForms;

ApplicationConfiguration.Initialize();
Application.Run(new MainForm());

internal sealed class MainForm : Form
{
    private readonly WebView2 _webView = new()
    {
        Dock = DockStyle.Fill
    };

    public MainForm()
    {
        Text = "WICI WebView2 Caret Host Initializing";
        Width = 900;
        Height = 500;
        Controls.Add(_webView);
        Shown += async (_, _) => await InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            await _webView.EnsureCoreWebView2Async();

            _webView.CoreWebView2.WebMessageReceived += (_, args) =>
            {
                var value = args.TryGetWebMessageAsString();
                Text = $"WICI WebView2 Caret Host Input={value}";
            };

            _webView.CoreWebView2.NavigationCompleted += async (_, args) =>
            {
                if (!args.IsSuccess)
                {
                    Text = $"WICI WebView2 Caret Host NavigationFailed={args.WebErrorStatus}";
                    return;
                }

                await _webView.CoreWebView2.ExecuteScriptAsync(
                    "document.getElementById('probe').focus(); document.getElementById('probe').setSelectionRange(0,0);");
                _webView.Focus();
                Text = "WICI WebView2 Caret Host Ready";
            };

            const string html = """
<!doctype html>
<meta charset="utf-8">
<title>WICI WebView2 caret host</title>
<style>
  body { font: 24px Segoe UI; padding: 60px; }
  input { width: 720px; font: 28px Consolas; padding: 8px; }
</style>
<input id="probe" autofocus oninput="chrome.webview.postMessage(this.value)">
""";

            _webView.NavigateToString(html);
        }
        catch (Exception ex)
        {
            Text = "WICI WebView2 Caret Host Error=" + ex.GetType().Name;
        }
    }
}
