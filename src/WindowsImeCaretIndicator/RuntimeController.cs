using System.Text.Json;
using Microsoft.Win32;
using System.Windows.Forms;

namespace WindowsImeCaretIndicator;

internal sealed class AppSettings
{
    public AppSettings()
    {
    }

    public bool StartWithWindows { get; set; } = true;

    public bool Paused { get; set; }

    public string? InstallExecutablePath { get; set; }

    private static string SettingsRoot =>
        Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            "WindowsImeCaretIndicator");

    internal static string SettingsDirectory =>
        Path.Combine(
            SettingsRoot,
            "StateV2");

    internal static string SettingsPath =>
        Path.Combine(
            SettingsDirectory,
            "settings.json");

    internal static string LegacySettingsPath =>
        Path.Combine(
            SettingsRoot,
            "settings.json");

    internal static bool CurrentSettingsFileExists =>
        File.Exists(SettingsPath);

    internal static AppSettings Load()
    {
        return TryLoadCurrent(out var settings)
            ? settings
            : new AppSettings();
    }

    internal static bool TryLoadCurrent(
        out AppSettings settings) =>
        TryLoadFromPath(
            SettingsPath,
            out settings);

    internal static bool TryLoadFromPath(
        string path,
        out AppSettings settings)
    {
        settings = new AppSettings();

        try
        {
            if (!File.Exists(path))
                return false;

            var loaded =
                JsonSerializer.Deserialize<AppSettings>(
                    File.ReadAllText(path));
            if (loaded is null)
                return false;

            settings = loaded;
            return true;
        }
        catch
        {
            return false;
        }
    }

    internal void Save()
    {
        var executable =
            Environment.ProcessPath;
        if (!ElevationSupport.IsElevated &&
            !string.IsNullOrWhiteSpace(executable))
        {
            InstallExecutablePath =
                Path.GetFullPath(executable);
        }

        Directory.CreateDirectory(
            SettingsDirectory);

        var temporaryPath =
            SettingsPath + ".tmp-" +
            Guid.NewGuid().ToString("N");

        try
        {
            File.WriteAllText(
                temporaryPath,
                JsonSerializer.Serialize(
                    this,
                    new JsonSerializerOptions
                    {
                        WriteIndented = true
                    }));

            File.Move(
                temporaryPath,
                SettingsPath,
                overwrite: true);
        }
        finally
        {
            try
            {
                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
            catch
            {
            }
        }
    }

    internal static void DeleteCurrentState()
    {
        try
        {
            if (File.Exists(SettingsPath))
                File.Delete(SettingsPath);
        }
        catch
        {
        }

        try
        {
            if (Directory.Exists(
                    SettingsDirectory) &&
                !Directory.EnumerateFileSystemEntries(
                    SettingsDirectory).Any())
            {
                Directory.Delete(
                    SettingsDirectory);
            }
        }
        catch
        {
        }
    }
}

internal static class StartupRegistration
{
    private const string RunKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Run";

    internal const string ValueName =
        "WindowsImeCaretIndicator.v2";

    internal const string LegacyValueName =
        "WindowsImeCaretIndicator";

    internal static void Apply(
        bool enabled)
    {
        var executable =
            Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable))
        {
            throw new InvalidOperationException(
                "The executable path is unavailable.");
        }

        ApplyForExecutable(
            enabled,
            executable);
    }

    internal static void ApplyForExecutable(
        bool enabled,
        string executable)
    {
        if (string.IsNullOrWhiteSpace(
                executable))
        {
            throw new ArgumentException(
                "Executable path is required.",
                nameof(executable));
        }

        using var key =
            Registry.CurrentUser.CreateSubKey(
                RunKeyPath,
                writable: true)
            ?? throw new InvalidOperationException(
                "Unable to open the user startup registry key.");

        if (!enabled)
        {
            key.DeleteValue(
                ValueName,
                throwOnMissingValue: false);
            return;
        }

        key.SetValue(
            ValueName,
            Quote(Path.GetFullPath(executable)),
            RegistryValueKind.String);
    }

    internal static bool IsRegistered()
    {
        var executable =
            Environment.ProcessPath;
        return !string.IsNullOrWhiteSpace(
                   executable) &&
               IsNamedValueForExecutable(
                   ValueName,
                   executable);
    }

    internal static string? ReadNamedValue(
        string valueName)
    {
        try
        {
            using var key =
                Registry.CurrentUser.OpenSubKey(
                    RunKeyPath,
                    writable: false);
            return key?.GetValue(
                valueName) as string;
        }
        catch
        {
            return null;
        }
    }

    internal static bool IsNamedValueForExecutable(
        string valueName,
        string executable)
    {
        if (string.IsNullOrWhiteSpace(
                executable))
        {
            return false;
        }

        try
        {
            var value =
                ReadNamedValue(valueName);
            return !string.IsNullOrWhiteSpace(
                       value) &&
                   string.Equals(
                       value,
                       Quote(
                           Path.GetFullPath(
                               executable)),
                       StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    internal static bool RemoveNamedValueIfMatches(
        string valueName,
        string executable)
    {
        if (!IsNamedValueForExecutable(
                valueName,
                executable))
        {
            return false;
        }

        using var key =
            Registry.CurrentUser.OpenSubKey(
                RunKeyPath,
                writable: true);
        if (key is null)
            return false;

        var value =
            key.GetValue(
                valueName) as string;
        if (!string.Equals(
                value,
                Quote(
                    Path.GetFullPath(
                        executable)),
                StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        key.DeleteValue(
            valueName,
            throwOnMissingValue: false);
        return true;
    }

    internal static string Quote(
        string value) =>
        $"\"{value}\"";
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
        _paused = _settings.Paused;

        _pauseItem = new ToolStripMenuItem("표시 일시 정지", null, (_, _) => SetPaused(true))
        {
            Visible = !_paused
        };
        _resumeItem = new ToolStripMenuItem("표시 재개", null, (_, _) => SetPaused(false))
        {
            Visible = _paused
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
        _settings.Paused = paused;
        try
        {
            _settings.Save();
        }
        catch
        {
        }
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
