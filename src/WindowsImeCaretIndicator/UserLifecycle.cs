using System.Security.Cryptography;
using Microsoft.Win32;

namespace WindowsImeCaretIndicator;

internal static class LegacyV010Lifecycle
{
    internal const string LegacyVersion = "0.1.0";
    internal const string LegacyExecutableSha256 =
        "35981ffa5c433dad472f91c5ee7752429cdcdf17f097a291608bdd103955d202";

    private const string ProductName =
        "Windows IME Caret Indicator";
    private const string ProductExecutableName =
        "WindowsImeCaretIndicator.exe";
    private const string LegacyUninstallKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{77D81AE7-1E91-56DB-B694-8E60C764A76D}_is1";

    internal static string LegacyInstallDirectory =>
        Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            "Programs",
            ProductName);

    internal static string LegacyExecutablePath =>
        Path.Combine(
            LegacyInstallDirectory,
            ProductExecutableName);

    internal static bool MigrateCurrentUserBestEffort()
    {
        if (ElevationSupport.IsElevated)
            return false;

        var currentExecutable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(currentExecutable) ||
            !ElevationSupport.IsProtectedElevationTarget(
                currentExecutable))
        {
            return false;
        }

        try
        {
            return MigrateCurrentUser(
                Path.GetFullPath(currentExecutable));
        }
        catch
        {
            return false;
        }
    }

    internal static bool CleanupCurrentUserForUninstallBestEffort()
    {
        var currentExecutable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(currentExecutable) ||
            !ElevationSupport.IsExpectedInstalledExecutablePath(
                currentExecutable))
        {
            return false;
        }

        try
        {
            var fullPath = Path.GetFullPath(currentExecutable);
            _ = StartupRegistration.RemoveNamedValueIfMatches(
                StartupRegistration.ValueName,
                fullPath);

            if (AppSettings.TryLoadCurrent(out var settings) &&
                IsSamePath(
                    settings.InstallExecutablePath,
                    fullPath))
            {
                AppSettings.DeleteCurrentState();
            }

            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool MigrateCurrentUser(
        string currentExecutable)
    {
        var legacySettingsExists =
            File.Exists(AppSettings.LegacySettingsPath);
        var legacySettingsValid =
            AppSettings.TryLoadFromPath(
                AppSettings.LegacySettingsPath,
                out var legacySettings);

        if (legacySettingsExists &&
            !legacySettingsValid)
        {
            return false;
        }

        var currentSettingsExists =
            AppSettings.CurrentSettingsFileExists;
        var currentSettingsValid =
            AppSettings.TryLoadCurrent(
                out var currentSettings);

        if (currentSettingsExists &&
            !currentSettingsValid)
        {
            return false;
        }

        var legacyRunOwned =
            StartupRegistration.IsNamedValueForExecutable(
                StartupRegistration.LegacyValueName,
                LegacyExecutablePath);
        var legacyExecutableOwned =
            IsExactLegacyExecutable();
        var legacyUninstallOwned =
            IsOwnedLegacyUninstallRegistration(
                out var legacyUninstaller);

        var hasLegacyState =
            legacySettingsExists ||
            legacyRunOwned ||
            legacyExecutableOwned ||
            legacyUninstallOwned;

        if (!hasLegacyState)
        {
            if (currentSettingsExists)
                return true;

            var initial = new AppSettings
            {
                StartWithWindows = true,
                Paused = false,
                InstallExecutablePath = currentExecutable
            };
            initial.Save();
            StartupRegistration.ApplyForExecutable(
                enabled: true,
                executable: currentExecutable);
            return true;
        }

        var selected = ChooseSettings(
            currentSettingsValid
                ? currentSettings
                : null,
            legacySettingsValid
                ? legacySettings
                : null,
            legacyRunOwned);

        selected.InstallExecutablePath =
            currentExecutable;
        selected.Save();

        StartupRegistration.ApplyForExecutable(
            selected.StartWithWindows,
            currentExecutable);

        if (legacyRunOwned)
        {
            _ = StartupRegistration.RemoveNamedValueIfMatches(
                StartupRegistration.LegacyValueName,
                LegacyExecutablePath);
        }

        if (legacySettingsValid)
            TryDeleteFile(AppSettings.LegacySettingsPath);

        if (legacyUninstallOwned)
            TryDeleteLegacyUninstallRegistration();

        if (legacyExecutableOwned)
            TryDeleteFile(LegacyExecutablePath);

        if (legacyUninstallOwned &&
            !string.IsNullOrWhiteSpace(
                legacyUninstaller))
        {
            TryDeleteLegacyUninstallerFiles(
                legacyUninstaller);
        }

        TryDeleteEmptyLegacyDirectory();
        return true;
    }

    internal static AppSettings ChooseSettings(
        AppSettings? current,
        AppSettings? legacy,
        bool legacyStartupOwned)
    {
        if (current is not null)
        {
            return new AppSettings
            {
                StartWithWindows =
                    current.StartWithWindows,
                Paused = current.Paused,
                InstallExecutablePath =
                    current.InstallExecutablePath
            };
        }

        if (legacy is not null)
        {
            return new AppSettings
            {
                StartWithWindows =
                    legacy.StartWithWindows,
                Paused = legacy.Paused
            };
        }

        return new AppSettings
        {
            StartWithWindows =
                legacyStartupOwned,
            Paused = false
        };
    }

    private static bool IsExactLegacyExecutable()
    {
        if (!File.Exists(LegacyExecutablePath))
            return false;

        try
        {
            using var stream = File.OpenRead(
                LegacyExecutablePath);
            var hash = Convert.ToHexString(
                SHA256.HashData(stream));
            return string.Equals(
                hash,
                LegacyExecutableSha256,
                StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static bool IsOwnedLegacyUninstallRegistration(
        out string? uninstallerPath)
    {
        uninstallerPath = null;

        try
        {
            using var key =
                Registry.CurrentUser.OpenSubKey(
                    LegacyUninstallKeyPath,
                    writable: false);
            if (key is null)
                return false;

            var displayName =
                key.GetValue("DisplayName") as string;
            var displayVersion =
                key.GetValue("DisplayVersion") as string;
            var uninstallString =
                key.GetValue("UninstallString") as string;
            var installLocation =
                key.GetValue("InstallLocation") as string;

            if (!string.Equals(
                    displayName,
                    ProductName,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    displayVersion,
                    LegacyVersion,
                    StringComparison.Ordinal))
            {
                return false;
            }

            var parsed = ExtractExecutablePath(
                uninstallString);
            if (string.IsNullOrWhiteSpace(parsed))
                return false;

            var fullUninstaller =
                Path.GetFullPath(parsed);
            var directory =
                Path.GetDirectoryName(
                    fullUninstaller);
            var fileName =
                Path.GetFileName(
                    fullUninstaller);

            if (!IsSamePath(
                    directory,
                    LegacyInstallDirectory) ||
                !fileName.StartsWith(
                    "unins",
                    StringComparison.OrdinalIgnoreCase) ||
                !fileName.EndsWith(
                    ".exe",
                    StringComparison.OrdinalIgnoreCase) ||
                !File.Exists(fullUninstaller))
            {
                return false;
            }

            if (!string.IsNullOrWhiteSpace(
                    installLocation) &&
                !IsSamePath(
                    installLocation,
                    LegacyInstallDirectory))
            {
                return false;
            }

            uninstallerPath =
                fullUninstaller;
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static string? ExtractExecutablePath(
        string? commandLine)
    {
        if (string.IsNullOrWhiteSpace(
                commandLine))
        {
            return null;
        }

        var trimmed = commandLine.Trim();
        if (trimmed.StartsWith('"'))
        {
            var closingQuote =
                trimmed.IndexOf('"', 1);
            return closingQuote > 1
                ? trimmed[1..closingQuote]
                : null;
        }

        var separator =
            trimmed.IndexOf(' ');
        return separator > 0
            ? trimmed[..separator]
            : trimmed;
    }

    private static void TryDeleteLegacyUninstallRegistration()
    {
        try
        {
            Registry.CurrentUser.DeleteSubKeyTree(
                LegacyUninstallKeyPath,
                throwOnMissingSubKey: false);
        }
        catch
        {
        }
    }

    private static void TryDeleteLegacyUninstallerFiles(
        string legacyUninstaller)
    {
        var directory =
            Path.GetDirectoryName(
                legacyUninstaller);
        if (!IsSamePath(
                directory,
                LegacyInstallDirectory) ||
            string.IsNullOrWhiteSpace(
                directory) ||
            !Directory.Exists(directory))
        {
            return;
        }

        foreach (var path in
                 Directory.EnumerateFiles(
                     directory,
                     "unins*.*",
                     SearchOption.TopDirectoryOnly))
        {
            var extension =
                Path.GetExtension(path);
            if (!extension.Equals(
                    ".exe",
                    StringComparison.OrdinalIgnoreCase) &&
                !extension.Equals(
                    ".dat",
                    StringComparison.OrdinalIgnoreCase) &&
                !extension.Equals(
                    ".msg",
                    StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            TryDeleteFile(path);
        }
    }

    private static void TryDeleteEmptyLegacyDirectory()
    {
        try
        {
            if (Directory.Exists(
                    LegacyInstallDirectory) &&
                !Directory.EnumerateFileSystemEntries(
                    LegacyInstallDirectory).Any())
            {
                Directory.Delete(
                    LegacyInstallDirectory);
            }
        }
        catch
        {
        }
    }

    private static void TryDeleteFile(
        string path)
    {
        try
        {
            if (File.Exists(path))
                File.Delete(path);
        }
        catch
        {
        }
    }

    private static bool IsSamePath(
        string? left,
        string? right)
    {
        if (string.IsNullOrWhiteSpace(left) ||
            string.IsNullOrWhiteSpace(right))
        {
            return false;
        }

        try
        {
            return string.Equals(
                Path.TrimEndingDirectorySeparator(
                    Path.GetFullPath(left)),
                Path.TrimEndingDirectorySeparator(
                    Path.GetFullPath(right)),
                StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}
