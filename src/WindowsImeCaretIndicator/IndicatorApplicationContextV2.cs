using System.Windows.Forms;

namespace WindowsImeCaretIndicator;

internal sealed class IndicatorApplicationContextV2 : ApplicationContext
{
    private readonly IndicatorOverlayForm _overlay = new();
    private readonly TextPattern2Bridge _caretResolver = new();
    private readonly ImeStateReader _imeStateReader = new();
    private readonly AppSettings _settings;
    private readonly bool _isElevated;
    private readonly bool _persistUserState;
    private readonly NotifyIcon _trayIcon;
    private readonly ToolStripMenuItem _pauseItem;
    private readonly ToolStripMenuItem _resumeItem;
    private readonly ToolStripMenuItem _elevateItem;
    private readonly ToolStripMenuItem _startupItem;
    private readonly System.Windows.Forms.Timer _coalesceTimer;
    private readonly System.Windows.Forms.Timer _fallbackTimer;
    private TrackingEvents? _trackingEvents;
    private UiaTextEventTracker? _uiaTextEvents;
    private bool _paused;
    private bool _disposed;

    internal IndicatorApplicationContextV2()
    {
        _isElevated = ElevationSupport.IsElevated;
        _persistUserState = !_isElevated;
        _settings = _persistUserState
            ? AppSettings.Load()
            : new AppSettings
            {
                StartWithWindows = false,
                Paused = false
            };
        _paused = _settings.Paused;
        var canRestartElevated =
            !_isElevated && ElevationSupport.CanRestartElevated;

        _pauseItem = new ToolStripMenuItem(
            "표시 일시 정지",
            null,
            (_, _) => SetPaused(true))
        {
            Visible = !_paused
        };

        _resumeItem = new ToolStripMenuItem(
            "표시 재개",
            null,
            (_, _) => SetPaused(false))
        {
            Visible = _paused
        };

        _elevateItem = new ToolStripMenuItem(
            _isElevated
                ? "관리자 권한으로 실행 중"
                : canRestartElevated
                    ? "관리자 권한으로 다시 시작"
                    : "관리자 권한 지원은 설치본에서 사용 가능",
            null,
            (_, _) => RestartElevated())
        {
            Enabled = canRestartElevated
        };

        _startupItem = new ToolStripMenuItem(
            _persistUserState
                ? "Windows 시작 시 자동 실행"
                : "Windows 시작 시 자동 실행 (일반 실행에서 설정)",
            null,
            (_, _) => ToggleStartup())
        {
            CheckOnClick = false,
            Checked = _persistUserState &&
                      StartupRegistration.IsRegistered(),
            Enabled = _persistUserState
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add(_pauseItem);
        menu.Items.Add(_resumeItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_elevateItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(
            new ToolStripMenuItem(
                "종료",
                null,
                (_, _) => ExitThread()));

        _trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Windows IME Caret Indicator",
            ContextMenuStrip = menu,
            Visible = true
        };

        _coalesceTimer = new System.Windows.Forms.Timer
        {
            Interval = 25
        };

        _coalesceTimer.Tick += (_, _) =>
        {
            _coalesceTimer.Stop();
            RefreshIndicator();
        };

        _fallbackTimer = new System.Windows.Forms.Timer
        {
            Interval = 750
        };

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
            _uiaTextEvents = new UiaTextEventTracker(RequestRefresh);
        }
        catch
        {
            _uiaTextEvents = null;
        }

        if (_persistUserState)
        {
            try
            {
                StartupRegistration.Apply(
                    _settings.StartWithWindows);
                _startupItem.Checked =
                    StartupRegistration.IsRegistered();
            }
            catch
            {
                _startupItem.Checked = false;
            }
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

        if (_coalesceTimer.Enabled)
            return;

        _coalesceTimer.Start();
    }

    private void RefreshIndicator()
    {
        if (_disposed || _paused)
        {
            _overlay.Dismiss();
            return;
        }

        if (!_caretResolver.TryGetActiveCaret(out var caret) ||
            caret is null)
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
        var bounds = OverlayPlacement.Choose(
            caret.Caret,
            size,
            workArea,
            gapX,
            gapY);

        _overlay.Present(bounds, ime.Mode);
    }

    private void SetPaused(bool paused)
    {
        _paused = paused;
        _settings.Paused = paused;
        if (_persistUserState)
        {
            try
            {
                _settings.Save();
            }
            catch
            {
            }
        }
        _pauseItem.Visible = !paused;
        _resumeItem.Visible = paused;

        if (paused)
            _overlay.Dismiss();
        else
            RequestRefresh();
    }

    private void RestartElevated()
    {
        if (_disposed || _isElevated)
            return;

        if (ElevationSupport.TryRestartElevated())
            ExitThread();
    }

    private void ToggleStartup()
    {
        if (!_persistUserState)
            return;

        var target = !_startupItem.Checked;

        try
        {
            StartupRegistration.Apply(target);
            _settings.StartWithWindows = target;
            _settings.Save();
            _startupItem.Checked =
                StartupRegistration.IsRegistered();
        }
        catch
        {
            _startupItem.Checked =
                StartupRegistration.IsRegistered();
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
        _uiaTextEvents?.Dispose();
        _caretResolver.Dispose();
        _overlay.Dismiss();
        _overlay.Dispose();
        _trayIcon.Visible = false;
        _trayIcon.Dispose();

        base.ExitThreadCore();
    }
}
