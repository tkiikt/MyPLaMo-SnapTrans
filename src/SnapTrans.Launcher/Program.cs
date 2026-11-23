using System.Diagnostics;
using System.Runtime.InteropServices;

namespace SnapTrans.Launcher;

/// <summary>
/// Starts app\MyPLaMo.SnapTrans.exe with the same arguments and exits right away (it does not stay resident).
/// The app finds its files from its own folder (AppContext.BaseDirectory), keeps itself single-instance,
/// and owns llama-server through a job object, so nothing depends on this process staying alive.
/// </summary>
internal static partial class Program
{
    const string AppExe = "MyPLaMo.SnapTrans.exe";

    [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int MessageBox(IntPtr hWnd, string text, string caption, uint type);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(int processId);

    private static int Main()
    {
        string appDir = Path.Combine(AppContext.BaseDirectory, "app");
        string target = Path.Combine(appDir, AppExe);
        if (!File.Exists(target))
        {
            MessageBox(IntPtr.Zero,
                $@"app\{AppExe} が見つかりません。ZIP をフォルダーごと展開してから起動してください。" + "\n\n" +
                $@"app\{AppExe} was not found. Extract the whole ZIP folder, then start the app again.",
                "MyPLaMo SnapTrans", 0x10 /* MB_ICONERROR */);
            return 2;
        }

        var psi = new ProcessStartInfo(target)
        {
            UseShellExecute = false,
            Arguments = ArgumentsTail(Environment.CommandLine), // pass the arguments through unchanged (e.g. --settings)
            // The app resolves everything from its own folder; using it as the working directory also keeps
            // the resident process from holding a handle on wherever the launcher was started from.
            WorkingDirectory = appDir,
        };
        try
        {
            // Let the app (or an already running instance it signals) bring its settings window to the front.
            AllowSetForegroundWindow(-1 /* ASFW_ANY */);
            using var p = Process.Start(psi)!;
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox(IntPtr.Zero, ex.Message, "MyPLaMo SnapTrans", 0x10);
            return 1;
        }
    }

    /// <summary>The command line without the leading exe path, keeping quotes as they were.</summary>
    private static string ArgumentsTail(string commandLine)
    {
        int i = 0;
        if (commandLine.StartsWith('"'))
        {
            i = commandLine.IndexOf('"', 1);
            i = i < 0 ? commandLine.Length : i + 1;
        }
        else
        {
            while (i < commandLine.Length && !char.IsWhiteSpace(commandLine[i])) i++;
        }
        return commandLine[i..].TrimStart();
    }
}
