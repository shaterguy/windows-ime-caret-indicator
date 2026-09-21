using System.Text.Json;
using Microsoft.Win32;
using System.Windows.Forms;

namespace WindowsImeCaretIndicator;

internal sealed class AppSettings
{
    public bool StartWithWindows { get; set; } = true;

    private static string SettingsDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "WindowsImeCaretIndicator");

    private static string SettingsPath =>
        Path.Combine(SettingsDirectory, "settings.json");

    internal static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
                return new AppSettings();

            return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath))
                ?? new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    internal void Save()
    {
        Directory.CreateDirectory(SettingsDirectory);
        File.WriteAllText(
            SettingsPath,
            JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}

internal static class StartupRegistration
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "WindowsImeCaretIndicator";

    internal static void Apply(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("Unable to open the user startup registry key.");

        if (!enabled)
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
            return;
        }

        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable))
            throw new InvalidOperationException("The executable path is unavailable.");

        key.SetValue(ValueName, Quote(executable), RegistryValueKind.String);
    }

    internal static bool IsRegistered()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            var value = key?.GetValue(ValueName) as string;
            var executable = Environment.ProcessPath;
            return !string.IsNullOrWhiteSpace(value) &&
                   !string.IsNullOrWhiteSpace(executable) &&
                   string.Equals(value, Quote(executable), StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static string Quote(string value) => $"\"{value}\"";
}

internal sealed class IndicatorApplicationContext : ApplicationContext
{
    private readonly IndicatorOverlayForm _overlay = new();
    private readonly CaretResolver _caretResolver = new();
    private readonly ImeStateReader _imeStateReader = new();
    private readonly AppSettings _settings;
    private readonly NotifyIcon _trayIcon;
    private readonly ToolStripMenuItem _pauseItem;
    private readonly ToolStripMenuItem _resumeItem;
    private readonly ToolStripMenuItem _startupItem;
    private readonly System.Windows.Forms.Timer _coalesceTimer;
    private readonly System.Windows.Forms.Timer _fallbackTimer;
    private TrackingEvents? _trackingEvents;
    private bool _paused;
    private bool _disposed;

    internal IndicatorApplicationContext()
    {
        _settings = AppSettings.Load();

        _pauseItem = new ToolStripMenuItem("표시 일시 정지", null, (_, _) => SetPaused(true));
        _resumeItem = new ToolStripMenuItem("표시 재개", null, (_, _) => SetPaused(false))
        {
            Visible = false
        };
        _startupItem = new ToolStripMenuItem(
            "Windows 시작 시 자동 실행",
            null,
            (_, _) => ToggleStartup())
        {
            CheckOnClick = false,
            Checked = StartupRegistration.IsRegistered()
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add(_pauseItem);
        menu.Items.Add(_resumeItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("종료", null, (_, _) => ExitThread()));

        _trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Windows IME Caret Indicator",
            ContextMenuStrip = menu,
            Visible = true
        };

        _coalesceTimer = new System.Windows.Forms.Timer { Interval = 25 };
        _coalesceTimer.Tick += (_, _) =>
        {
            _coalesceTimer.Stop();
            RefreshIndicator();
        };

        _fallbackTimer = new System.Windows.Forms.Timer { Interval = 750 };
        _fallbackTimer.Tick += (_, _) => RefreshIndicator();
        _fallbackTimer.Start();

        _ = _overlay.Handle;

        try
        {
            _trackingEvents = new TrackingEvents(RequestRefresh);
        }
        catch
        {
            _trackingEvents = null;
        }

        try
        {
            StartupRegistration.Apply(_settings.StartWithWindows);
            _startupItem.Checked = StartupRegistration.IsRegistered();
        }
        catch
        {
            _startupItem.Checked = false;
        }

        RequestRefresh();
    }

    private void RequestRefresh()
    {
        if (_disposed)
            return;

        if (_overlay.InvokeRequired)
        {
            try
            {
                _overlay.BeginInvoke((Action)RequestRefresh);
            }
            catch (InvalidOperationException)
            {
            }
            return;
        }

        _coalesceTimer.Stop();
        _coalesceTimer.Start();
    }

    private void RefreshIndicator()
    {
        if (_disposed || _paused)
        {
            _overlay.Dismiss();
            return;
        }

        if (!_caretResolver.TryGetActiveCaret(out var caret) || caret is null)
        {
            _overlay.Dismiss();
            return;
        }

        var ime = _imeStateReader.Read(caret);
        if (ime.Mode is ImeMode.Unknown)
        {
            _overlay.Dismiss();
            return;
        }

        var dpi = Native.GetDpiForWindow(caret.FocusWindow);
        if (dpi == 0)
            dpi = 96;

        var size = OverlayMetrics.CalculateSize(caret.Caret, dpi);
        var (gapX, gapY) = OverlayMetrics.CalculateGap(dpi);
        var workArea = Screen.FromRectangle(caret.Caret).WorkingArea;
        var bounds = OverlayPlacement.Choose(caret.Caret, size, workArea, gapX, gapY);

        _overlay.Present(bounds, ime.Mode);
    }

    private void SetPaused(bool paused)
    {
        _paused = paused;
        _pauseItem.Visible = !paused;
        _resumeItem.Visible = paused;

        if (paused)
            _overlay.Dismiss();
        else
            RequestRefresh();
    }

    private void ToggleStartup()
    {
        var target = !_startupItem.Checked;

        try
        {
            StartupRegistration.Apply(target);
            _settings.StartWithWindows = target;
            _settings.Save();
            _startupItem.Checked = StartupRegistration.IsRegistered();
        }
        catch
        {
            _startupItem.Checked = StartupRegistration.IsRegistered();
        }
    }

    protected override void ExitThreadCore()
    {
        if (_disposed)
            return;

        _disposed = true;
        _coalesceTimer.Stop();
        _fallbackTimer.Stop();
        _trackingEvents?.Dispose();
        _caretResolver.Dispose();
        _overlay.Dismiss();
        _overlay.Dispose();
        _trayIcon.Visible = false;
        _trayIcon.Dispose();

        base.ExitThreadCore();
    }
}
