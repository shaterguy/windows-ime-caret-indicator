using System.Text.Json;
using Microsoft.Win32;

namespace WindowsImeCaretIndicator;

internal static class UserInstallIdentity
{
    internal const string RegistryPath =
        @"Software\SHatergUY\Windows IME Caret Indicator";
    internal const string GenerationValueName = "Generation";
    internal const string ExecutablePathValueName = "ExecutablePath";
    internal const string Generation = "programfiles-v2";

    internal static void WriteCurrent(string executable)
    {
        if (!ElevationSupport.IsProtectedElevationTarget(executable))
        {
            throw new InvalidOperationException(
                "The current executable is not a protected installed product target.");
        }

        using var key = Registry.CurrentUser.CreateSubKey(
            RegistryPath,
            writable: true)
            ?? throw new InvalidOperationException(
                "Unable to open the current-user product identity key.");

        key.SetValue(
            GenerationValueName,
            Generation,
            RegistryValueKind.String);
        key.SetValue(
            ExecutablePathValueName,
            Path.GetFullPath(executable),
            RegistryValueKind.String);
    }

    internal static bool IsCurrent(string executable)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                RegistryPath,
                writable: false);
            var generation =
                key?.GetValue(GenerationValueName) as string;
            var recordedPath =
                key?.GetValue(ExecutablePathValueName) as string;

            return string.Equals(
                       generation,
                       Generation,
                       StringComparison.Ordinal) &&
                   !string.IsNullOrWhiteSpace(recordedPath) &&
                   string.Equals(
                       Path.GetFullPath(recordedPath),
                       Path.GetFullPath(executable),
                       StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}

internal static class LegacyV010Migration
{
    internal const string LegacyVersion = "0.1.0";
    internal const string LegacyRunValueName =
        "WindowsImeCaretIndicator";
    internal const string LegacyUninstallKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{77D81AE7-1E91-56DB-B694-8E60C764A76D}_is1";

    private const string ProductDisplayName =
        "Windows IME Caret Indicator";
    private const string RunKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Run";

    internal static string LegacyInstallDirectory =>
        Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            "Programs",
            ProductInstallIdentity.ProductDirectoryName);

    internal static string LegacyExecutable =>
        Path.Combine(
            LegacyInstallDirectory,
            ProductInstallIdentity.ExecutableName);

    internal static string LegacySettingsPath =>
        Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            "WindowsImeCaretIndicator",
            "settings.json");

    internal static void RunAtStartup()
    {
        if (ElevationSupport.IsElevated)
            return;

        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) ||
            !ProductInstallIdentity.IsExpectedInstalledExecutable(
                executable))
        {
            return;
        }

        if (!ElevationSupport.IsProtectedElevationTarget(executable))
        {
            throw new InvalidOperationException(
                "Installed product trust validation failed.");
        }

        MigrateCurrentUser(executable);
    }

    internal static int RunExplicit()
    {
        if (ElevationSupport.IsElevated)
            return 0;

        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) ||
            !ProductInstallIdentity.IsExpectedInstalledExecutable(
                executable))
        {
            return 0;
        }

        if (!ElevationSupport.IsProtectedElevationTarget(executable))
            return 5;

        try
        {
            MigrateCurrentUser(executable);
            return 0;
        }
        catch
        {
            return 5;
        }
    }

    private static void MigrateCurrentUser(
        string protectedExecutable)
    {
        var legacyRunOwned =
            IsExactLegacyRunRegistration();
        var legacyUninstallOwned =
            IsExactLegacyUninstallRegistration();
        var legacyOwned =
            legacyRunOwned || legacyUninstallOwned;

        var settings = File.Exists(AppSettings.SettingsPath)
            ? AppSettings.Load()
            : legacyOwned
                ? DetermineMigratedSettings(
                    TryReadLegacySettings(),
                    legacyRunOwned)
                : new AppSettings();

        settings.Save();
        StartupRegistration.Apply(
            settings.StartWithWindows);
        UserInstallIdentity.WriteCurrent(
            protectedExecutable);

        if (legacyRunOwned)
            RemoveExactLegacyRunRegistration();

        if (legacyUninstallOwned)
        {
            if (File.Exists(LegacySettingsPath))
                File.Delete(LegacySettingsPath);

            DeleteKnownLegacyFiles();
            Registry.CurrentUser.DeleteSubKeyTree(
                LegacyUninstallKeyPath,
                throwOnMissingSubKey: false);
        }
    }

    internal static AppSettings DetermineMigratedSettings(
        AppSettings? legacySettings,
        bool legacyRunOwned)
    {
        if (legacySettings is not null)
        {
            return new AppSettings
            {
                StartWithWindows =
                    legacySettings.StartWithWindows,
                Paused = legacySettings.Paused
            };
        }

        return new AppSettings
        {
            StartWithWindows = legacyRunOwned,
            Paused = false
        };
    }

    private static AppSettings? TryReadLegacySettings()
    {
        try
        {
            if (!File.Exists(LegacySettingsPath))
                return null;

            return JsonSerializer.Deserialize<AppSettings>(
                File.ReadAllText(LegacySettingsPath));
        }
        catch
        {
            return null;
        }
    }

    private static bool IsExactLegacyRunRegistration()
    {
        using var key = Registry.CurrentUser.OpenSubKey(
            RunKeyPath,
            writable: false);
        var value = key?.GetValue(
            LegacyRunValueName) as string;

        return string.Equals(
            value,
            StartupRegistration.Quote(
                LegacyExecutable),
            StringComparison.OrdinalIgnoreCase);
    }

    private static void RemoveExactLegacyRunRegistration()
    {
        using var key = Registry.CurrentUser.OpenSubKey(
            RunKeyPath,
            writable: true)
            ?? throw new InvalidOperationException(
                "Unable to open the current-user startup key.");

        var value = key.GetValue(
            LegacyRunValueName) as string;
        if (!string.Equals(
                value,
                StartupRegistration.Quote(
                    LegacyExecutable),
                StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        key.DeleteValue(
            LegacyRunValueName,
            throwOnMissingValue: false);
    }

    private static bool IsExactLegacyUninstallRegistration()
    {
        using var key = Registry.CurrentUser.OpenSubKey(
            LegacyUninstallKeyPath,
            writable: false);

        if (key is null)
            return false;

        return IsExpectedLegacyUninstallIdentity(
            key.GetValue("DisplayName") as string,
            key.GetValue("DisplayVersion") as string,
            key.GetValue("InstallLocation") as string,
            key.GetValue("UninstallString") as string);
    }

    internal static bool IsExpectedLegacyUninstallIdentity(
        string? displayName,
        string? displayVersion,
        string? installLocation,
        string? uninstallString)
    {
        if (!string.Equals(
                displayName,
                ProductDisplayName,
                StringComparison.Ordinal) ||
            !string.Equals(
                displayVersion,
                LegacyVersion,
                StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(uninstallString))
        {
            return false;
        }

        try
        {
            if (!string.IsNullOrWhiteSpace(
                    installLocation) &&
                !string.Equals(
                    NormalizeDirectory(installLocation),
                    NormalizeDirectory(
                        LegacyInstallDirectory),
                    StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            var uninstallExecutable =
                ExtractExecutablePath(
                    uninstallString);
            if (string.IsNullOrWhiteSpace(
                    uninstallExecutable))
            {
                return false;
            }

            var uninstallFullPath =
                Path.GetFullPath(
                    uninstallExecutable);
            var uninstallDirectory =
                Path.GetDirectoryName(
                    uninstallFullPath);
            var uninstallFileName =
                Path.GetFileName(
                    uninstallFullPath);

            return !string.IsNullOrWhiteSpace(
                       uninstallDirectory) &&
                   string.Equals(
                       NormalizeDirectory(
                           uninstallDirectory),
                       NormalizeDirectory(
                           LegacyInstallDirectory),
                       StringComparison.OrdinalIgnoreCase) &&
                   uninstallFileName.StartsWith(
                       "unins",
                       StringComparison.OrdinalIgnoreCase) &&
                   uninstallFileName.EndsWith(
                       ".exe",
                       StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static string NormalizeDirectory(
        string path) =>
        Path.TrimEndingDirectorySeparator(
            Path.GetFullPath(path));

    private static string? ExtractExecutablePath(
        string uninstallString)
    {
        var value = uninstallString.Trim();
        if (value.Length == 0)
            return null;

        if (value[0] == '"')
        {
            var end = value.IndexOf('"', 1);
            return end > 1
                ? value[1..end]
                : null;
        }

        var separator = value.IndexOf(' ');
        return separator > 0
            ? value[..separator]
            : value;
    }

    private static void DeleteKnownLegacyFiles()
    {
        if (!Directory.Exists(LegacyInstallDirectory))
            return;

        foreach (var file in Directory.EnumerateFiles(
                     LegacyInstallDirectory))
        {
            var fileName = Path.GetFileName(file);
            var known =
                string.Equals(
                    fileName,
                    ProductInstallIdentity.ExecutableName,
                    StringComparison.OrdinalIgnoreCase) ||
                IsKnownUninstallerFile(fileName);

            if (known)
                File.Delete(file);
        }

        if (!Directory.EnumerateFileSystemEntries(
                LegacyInstallDirectory).Any())
        {
            Directory.Delete(LegacyInstallDirectory);
        }
    }

    private static bool IsKnownUninstallerFile(
        string fileName)
    {
        if (!fileName.StartsWith(
                "unins",
                StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var extension = Path.GetExtension(fileName);
        return extension.Equals(
                   ".exe",
                   StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(
                   ".dat",
                   StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(
                   ".msg",
                   StringComparison.OrdinalIgnoreCase);
    }
}
