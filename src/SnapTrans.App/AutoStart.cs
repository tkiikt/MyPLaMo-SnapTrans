using Microsoft.Win32;

namespace SnapTrans.App;

/// <summary>
/// "Start at sign-in": one value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run (no admin rights needed).
/// The state lives only in the registry, never in settings.json. Only our own value name is read or written;
/// the other values under Run belong to the user and other apps and are never touched.
/// </summary>
public static class AutoStart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string ValueName = "MyPLaMo SnapTrans";
    public const string Argument = "--autostart";
    const string LauncherExe = "MyPLaMo-SnapTrans.exe";

    /// <summary>True when this process was started by the Run entry (sign-in): stay in the tray, no settings window.</summary>
    public static bool LaunchedAtSignIn => Environment.GetCommandLineArgs().Skip(1).Any(a => string.Equals(a, Argument, StringComparison.OrdinalIgnoreCase));

    /// <summary>True when <see cref="RepairLocation"/> rewrote the entry in this session (the ZIP folder was moved).</summary>
    public static bool RelocatedThisSession { get; private set; }

    /// <summary>
    /// The exe the Run entry starts: the distribution ZIP's launcher (..\MyPLaMo-SnapTrans.exe next to the app folder)
    /// when it is there, otherwise this exe (development builds).
    /// </summary>
    public static string TargetExe
    {
        get
        {
            var appDir = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
            var launcher = Path.Combine(Path.GetDirectoryName(appDir) ?? appDir, LauncherExe);
            if (string.Equals(Path.GetFileName(appDir), "app", StringComparison.OrdinalIgnoreCase) && File.Exists(launcher)) return launcher;
            return Environment.ProcessPath ?? Path.Combine(appDir, "MyPLaMo.SnapTrans.exe");
        }
    }

    public static string ExpectedCommand => $"\"{TargetExe}\" {Argument}";

    /// <summary>Our Run value, or null when it is not registered (or cannot be read).</summary>
    public static string? RegisteredCommand
    {
        get
        {
            try {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
                return key?.GetValue(ValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
            } catch (Exception ex) {
                AppHost.LogError("autostart read", ex);
                return null;
            }
        }
    }

    public static bool IsEnabled => !string.IsNullOrWhiteSpace(RegisteredCommand);

    /// <summary>Registers (on) or removes (off) our Run value. Throws on failure so the UI can show it.</summary>
    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled) {
            key.SetValue(ValueName, ExpectedCommand, RegistryValueKind.String);
            AppHost.Log("autostart: registered");
        } else {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
            AppHost.Log("autostart: removed");
        }
    }

    /// <summary>
    /// At startup: when the switch is on but the entry points somewhere else (the ZIP folder was moved or renamed),
    /// point it at this copy. When the switch is off, nothing is done.
    /// </summary>
    public static void RepairLocation()
    {
        var current = RegisteredCommand;
        if (string.IsNullOrWhiteSpace(current)) return;
        var expected = ExpectedCommand;
        if (string.Equals(current.Trim(), expected, StringComparison.OrdinalIgnoreCase)) return;
        try {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null) return;
            key.SetValue(ValueName, expected, RegistryValueKind.String);
            RelocatedThisSession = true;
            // Paths are never logged.
            AppHost.Log("autostart: entry pointed to another location; updated to this copy");
        } catch (Exception ex) {
            AppHost.LogError("autostart update", ex);
        }
    }
}
