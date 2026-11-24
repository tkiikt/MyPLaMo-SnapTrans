using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Xaml;

namespace SnapTrans.App;

public partial class App : Application
{
    public static AppHost? Host { get; private set; }
    Mutex? instance;

    public App()
    {
        InitializeComponent();
        // Tray app: closing the settings window must not end the process.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) => { AppHost.LogError("unhandled", e.Exception); e.Handled = true; };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var profile = Environment.GetEnvironmentVariable("SNAPTRANS_PROFILE");
        var suffix = string.IsNullOrEmpty(profile) ? "" : "." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(profile)))[..16];
        instance = new Mutex(true, "Local\\MyPLaMo.SnapTrans" + suffix, out var first);
        // Launching the exe again opens the settings of the running instance.
        var show = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\MyPLaMo.SnapTrans.Show" + suffix);
        bool atSignIn = AutoStart.LaunchedAtSignIn;
        if (!first) {
            // A sign-in start while SnapTrans already runs stays silent; any other launch opens its settings.
            if (!atSignIn) show.Set();
            Exit();
            return;
        }
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        ThreadPool.RegisterWaitForSingleObject(show, (_, _) => ui.TryEnqueue(() => Host?.OpenSettings()), null, -1, false);
        if (atSignIn) AppHost.Log("started at sign-in");
        // The ZIP folder may have moved since the switch was turned on: keep the Run entry pointing at this copy.
        AutoStart.RepairLocation();
        Host = new AppHost();
        Host.Start(quiet: atSignIn);
        if (Environment.GetCommandLineArgs().Contains("--settings")) Host.OpenSettings();
    }
}
