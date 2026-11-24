using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using SnapTrans.App.Native;
using SnapTrans.Core;
using SnapTrans.Llama;
using SnapTrans.Ocr.Tesseract;
using SnapTrans.Ocr.Windows;

namespace SnapTrans.App;

/// <summary>Tray app: owns the tray icon, the global drag selection, OCR/translation engines and the windows.</summary>
public sealed class AppHost
{
    public AppSettings Settings { get; } = AppSettings.Load();
    public EngineLocator Engines { get; } = new(Path.Combine(AppContext.BaseDirectory, "engine"), AppSettings.EngineRoot);
    public PlamoTranslator Translator { get; }
    public WindowsMediaOcr WindowsOcr { get; } = new();
    public TesseractOcr Tesseract { get; } = new(AppSettings.TessdataFolder);
    public DeviceCatalog? Devices { get; set; }
    public string LastSource { get; private set; } = "";
    public string LastTranslation { get; private set; } = "";
    /// <summary>True while a device/model/folder change waits for running work to stop.</summary>
    public bool EngineChanging { get; private set; }
    /// <summary>Model ids currently being hashed (first use / file changed).</summary>
    public HashSet<string> Verifying { get; } = [];
    public string? HookError => input.HookError;
    public bool AnotherInstanceOwnsHooks => input.AnotherInstanceOwnsHooks;
    public event Action? StateChanged;

    readonly DispatcherQueue ui = DispatcherQueue.GetForCurrentThread();
    readonly TrayIcon tray;
    readonly SnapInput input;
    PopupWindow? popup;
    SettingsWindow? settingsWindow;
    CancellationTokenSource? job;
    readonly CancellationTokenSource lifetime = new();
    bool exiting;
    LoadedEngine? announcedFallback;

    public AppHost()
    {
        // SHA-256 results live in SnapTrans' profile, never next to the models (the folder may belong to another app).
        VerificationCache.FilePath = Path.Combine(AppSettings.Home, "verify-cache.json");
        Loc.Init(Settings.Language);
        Translator = new PlamoTranslator(Engines);
        Translator.Loading += d => ui.TryEnqueue(() => popup?.SetStage(Loc.F("Stage_Loading", d.Label)));
        Translator.Diagnostic += m => Log("engine: " + m);
        // Before each load the engine hands us a write-denying handle to the model; check it against the official versions.
        Translator.ModelGuard = (stream, ct) => ModelInfo.Find(Settings.ModelId) is { } model ? ModelStore.GuardAsync(model, stream, ct) : Task.CompletedTask;
        Translator.Configure(ActiveModelPath, Settings.Device);
        var assets = Path.Combine(AppContext.BaseDirectory, "Assets");
        tray = new TrayIcon(Path.Combine(assets, "TrayLight.ico"), Path.Combine(assets, "TrayDark.ico"), Loc.T("AppName"));
        tray.ThemeApplied += light => Log($"tray icon: {(light ? "light" : "dark")} taskbar");
        Log($"tray icon: {(tray.LightTaskbar ? "light" : "dark")} taskbar");
        tray.Activated += OpenSettings;
        tray.MenuItems = () => [
            (1, Loc.T("Tray_Settings"), false),
            (2, Loc.T("Tray_Last"), false),
            (3, Loc.T("Tray_Enabled"), Settings.Enabled),
            (0, null, false),
            (9, Loc.T("Tray_Exit"), false),
        ];
        tray.Command += id => {
            switch (id) {
                case 1: OpenSettings(); break;
                case 2: ShowLast(); break;
                case 3: Settings.Enabled = !Settings.Enabled; input!.Enabled = Settings.Enabled; Settings.Save(); break;
                case 9: _ = ExitAsync(); break;
            }
        };
        input = new SnapInput { Modifiers = Settings.Modifiers, Enabled = Settings.Enabled };
        input.Began += () => ui.TryEnqueue(() => { CancelJob(); popup?.Hide(); });
        input.Canceled += reason => Log("selection canceled: " + reason);
        input.Completed += (rect, image) => ui.TryEnqueue(() => _ = RunAsync(rect, image));
        input.BeforeCapture = () => {
            var hidden = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!ui.TryEnqueue(() => { try { popup?.Hide(); } finally { hidden.TrySetResult(); } })) hidden.TrySetResult();
            return hidden.Task;
        };
        UpdateTip();
        Loc.Changed += () => { UpdateTip(); popup?.ApplyStrings(); };
    }

    /// <param name="quiet">Started at sign-in: stay in the tray and report problems with a balloon only (no settings window).</param>
    public void Start(bool quiet = false)
    {
        void ShowSettings() { if (!quiet) OpenSettings(); }
        if (input.AnotherInstanceOwnsHooks) {
            Log("input hooks: owned by another SnapTrans instance");
            tray.ShowBalloon(Loc.T("AppName"), Loc.T("Hook_OtherInstance"));
            ShowSettings();
            return;
        }
        if (input.HookError is { } hookError) {
            // Without the hooks drag-to-translate cannot work: say so instead of showing "ready".
            Log("hook install failed: " + hookError);
            tray.ShowBalloon(Loc.T("AppName"), Loc.T("Hook_Failed"));
            ShowSettings();
            return;
        }
        var m = ModelInfo.Find(Settings.ModelId);
        var state = m == null ? ModelState.Missing : new ModelStore(Settings.ModelFolder).StateOf(m);
        if (state is ModelState.Ready or ModelState.Outdated or ModelState.Unverified) {
            tray.ShowBalloon(Loc.T("AppName"), Loc.F("Balloon_Ready", ShortcutText(Settings.Modifiers)));
            _ = EnsureVerifiedAsync(preload: true);
        } else {
            ShowSettings();
            tray.ShowBalloon(Loc.T("AppName"), Loc.T(state == ModelState.Corrupt ? "Balloon_Corrupt" : "Balloon_NoModel"));
        }
    }

    /// <summary>The selected model, only when its size and SHA-256 have been verified for this exact file.</summary>
    public ModelInfo? ActiveModel => ModelInfo.Find(Settings.ModelId) is { } m && new ModelStore(Settings.ModelFolder).StateOf(m) is ModelState.Ready or ModelState.Outdated ? m : null;
    string ActiveModelPath => ActiveModel is { } m ? new ModelStore(Settings.ModelFolder).PathOf(m) : "";

    /// <summary>Hashes the selected model once if it is new or changed (result cached by ModelStore), then optionally preloads.</summary>
    public async Task EnsureVerifiedAsync(bool preload)
    {
        if (ModelInfo.Find(Settings.ModelId) is not { } m) return;
        var store = new ModelStore(Settings.ModelFolder);
        if (store.StateOf(m) == ModelState.Unverified && Verifying.Add(m.Id)) {
            StateChanged?.Invoke();
            try { await Task.Run(() => store.VerifyAsync(m, null, lifetime.Token)); Log($"verified {m.Id}"); }
            catch (Exception ex) when (ex is not OperationCanceledException) {
                LogError($"verify {m.Id}", ex);
                tray.ShowBalloon(Loc.T("AppName"), Loc.T("Balloon_Corrupt"));
            } finally { Verifying.Remove(m.Id); }
            if (lifetime.IsCancellationRequested) return;
            await ApplyEngineChangeAsync(null, preload);
            return;
        }
        if (preload) Preload();
        StateChanged?.Invoke();
    }

    /// <summary>Loads the model in the background so the first drag is fast.</summary>
    public void Preload()
    {
        if (ActiveModel == null || exiting) return;
        _ = Task.Run(async () => {
            try { await Translator.EnsureLoadedAsync(lifetime.Token); } catch (Exception ex) when (ex is not OperationCanceledException) { LogError("preload", ex); } catch (OperationCanceledException) { }
            ui.TryEnqueue(() => StateChanged?.Invoke());
        });
    }

    /// <summary>
    /// Applies a device / model / folder change without blocking the UI thread: running OCR/translation is
    /// cancelled, the engine waits asynchronously for in-flight work, then restarts with the new configuration.
    /// </summary>
    public async Task ApplyEngineChangeAsync(Action? mutate, bool preload = true)
    {
        if (exiting) return;
        CancelJob();
        mutate?.Invoke();
        Settings.Save();
        EngineChanging = true;
        StateChanged?.Invoke();
        try { await Translator.ResetAsync(ActiveModelPath, Settings.Device); }
        finally { EngineChanging = false; }
        if (preload) Preload();
        StateChanged?.Invoke();
    }

    public void ApplyModifiers() { input.Modifiers = Settings.Modifiers; UpdateTip(); }

    void UpdateTip() => tray.SetTip(input.HookError != null ? Loc.T("Hook_Failed") : Loc.F("Tray_Tip", ShortcutText(Settings.Modifiers)));

    public static string ShortcutText(SnapModifiers m)
    {
        var parts = new List<string>();
        if (m.HasFlag(SnapModifiers.Ctrl)) parts.Add("Ctrl");
        if (m.HasFlag(SnapModifiers.Alt)) parts.Add("Alt");
        if (m.HasFlag(SnapModifiers.Shift)) parts.Add("Shift");
        if (m.HasFlag(SnapModifiers.Win)) parts.Add("Win");
        return string.Join(" + ", parts);
    }

    public ElementTheme ElementTheme => Settings.Theme switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };

    public void ApplyTheme() { settingsWindow?.ApplyTheme(); popup?.ApplyTheme(); }

    IOcrEngine Ocr => Settings.OcrEngine == "tesseract" && Tesseract.AvailableLanguages.Count > 0 ? Tesseract : WindowsOcr;

    PopupWindow Popup()
    {
        if (popup == null || popup.IsClosed) popup = new PopupWindow();
        return popup;
    }

    void CancelJob()
    {
        // The CTS is disposed by the RunAsync that owns it; cancelling a disposed one is harmless to skip.
        try { job?.Cancel(); } catch (ObjectDisposedException) { }
    }

    async Task RunAsync(Win32.RECT rect, OcrImage? image)
    {
        if (exiting) return;
        CancelJob();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        job = cts;
        var card = Popup();
        card.ShowAt(rect, Loc.T("Stage_Recognizing"));
        string original = "";
        try {
            if (image == null) throw new IOException("Screen capture failed.");
            var ocr = Ocr;
            var lang = Settings.OcrLanguage;
            var recognized = await Task.Run(() => ocr.RecognizeAsync(image, lang, cts.Token), cts.Token);
            original = recognized.Text;
            if (cts.IsCancellationRequested) return;
            if (string.IsNullOrWhiteSpace(original)) { card.SetError(Loc.T("NoText"), ""); Log("no text recognized"); return; }
            if (ActiveModel == null) {
                if (ModelInfo.Find(Settings.ModelId) is { } dbgModel) Log($"no active model: state={new ModelStore(Settings.ModelFolder).StateOf(dbgModel)}");
                // Nothing was translated: keep "last translation" (source + result) as it was.
                var key = Verifying.Contains(Settings.ModelId) ? "Err_ModelVerifying" : "Err_NoModel";
                card.SetError(Loc.T(key), original);
                if (key == "Err_NoModel") OpenSettings();
                return;
            }
            if (EngineChanging) card.SetStage(Loc.T("Stage_Switching"));
            else card.SetStage(Translator.Loaded == null ? Loc.F("Stage_Loading", "…") : Loc.T("Stage_Translating"));
            var to = LanguageGuess.ResolveTarget(original, Settings.Target);
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var result = await Task.Run(() => Translator.TranslateAsync(new TranslationRequest(original, "", to), cts.Token), cts.Token);
            if (cts.IsCancellationRequested) return;
            var loaded = Translator.Loaded;
            LastSource = original; LastTranslation = result.Text;
            // Header shows the model size only; device and timing go to the log, warnings to an icon + tooltip.
            var status = ActiveModel?.Id.ToUpperInvariant() ?? "";
            string? note = loaded?.FallbackReason is { } reason ? Loc.F("Fallback", ReasonText(reason)) : null;
            if (note != null && loaded != announcedFallback) { announcedFallback = loaded; tray.ShowBalloon(Loc.T("AppName"), note); }
            card.SetResult(result.Text, original, status, note);
            StateChanged?.Invoke();
            Log($"ocr={recognized.Elapsed.TotalMilliseconds:0}ms lang={recognized.LanguageTag} translate={result.Elapsed.TotalMilliseconds:0}ms device={loaded?.Device.Label} chars={original.Length}");
        } catch (OperationCanceledException) when (cts.IsCancellationRequested || lifetime.IsCancellationRequested) {
        } catch (OperationCanceledException) {
            // The engine was reset underneath us (device/model change): not an error for the user.
            if (!exiting) card.SetError(Loc.T("Canceled"), original);
        } catch (Exception ex) {
            LogError("translate", ex);
            if (!cts.IsCancellationRequested) card.SetError(Loc.Error(ex), original);
        } finally {
            if (ReferenceEquals(job, cts)) job = null;
        }
    }

    public static string ReasonText(string reason)
    {
        var code = reason.Split(':')[0];
        return Loc.T("Err_" + code) is var t && t != "Err_" + code ? t + (reason.Contains(':') ? reason[reason.IndexOf(':')..] : "") : reason;
    }

    void ShowLast()
    {
        if (LastTranslation.Length == 0) { OpenSettings(); return; }
        Win32.GetCursorPos(out var pt);
        var card = Popup();
        card.ShowAt(new Win32.RECT(pt.X - 200, pt.Y - 10, pt.X + 200, pt.Y), "");
        card.SetResult(LastTranslation, LastSource, "", null);
    }

    public void OpenSettings()
    {
        if (exiting) return;
        if (settingsWindow == null) {
            settingsWindow = new SettingsWindow(this);
            settingsWindow.Closed += (_, _) => settingsWindow = null;
        }
        settingsWindow.Activate();
        Win32.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(settingsWindow));
    }

    static readonly object LogSync = new();
    const long LogLimit = 1_000_000; // bytes; one previous file (snaptrans.log.1) is kept

    /// <summary>
    /// Diagnostic log. Callers pass fixed text and numbers only: no recognized or translated text, no file paths, no
    /// keys, no raw exception messages (use <see cref="LogError"/>). Rotated at 1 MB.
    /// </summary>
    public static void Log(string line)
    {
        try {
            lock (LogSync) {
                Directory.CreateDirectory(AppSettings.Home);
                var path = Path.Combine(AppSettings.Home, "snaptrans.log");
                var info = new FileInfo(path);
                if (info.Exists && info.Length > LogLimit) File.Move(path, path + ".1", overwrite: true);
                File.AppendAllText(path, $"{DateTimeOffset.Now:O} {line}\n");
            }
        } catch { }
    }

    /// <summary>
    /// Logs an exception through an allowlist: its type, the SnapTrans error code and only short, path-free arguments
    /// (numbers and simple words). Messages and stack traces can contain paths or text, so they are never written.
    /// </summary>
    public static void LogError(string context, Exception ex)
    {
        var inner = ex is AggregateException { InnerException: { } i } ? i : ex;
        var detail = inner is SnapTransException se
            ? $"{se.Code}{(se.Args.Length > 0 ? " " + string.Join(" ", se.Args.Select(SafeArg)) : "")}"
            : $"{inner.GetType().Name} 0x{inner.HResult:X8}";
        Log($"{context}: {detail}");
    }

    static string SafeArg(object? arg) => arg switch {
        int or long or double => Convert.ToString(arg, System.Globalization.CultureInfo.InvariantCulture)!,
        string s when s.Length <= 40 && System.Text.RegularExpressions.Regex.IsMatch(s, @"^[A-Za-z0-9 ._:+-]*$") => s,
        _ => "?"
    };

    /// <summary>
    /// Orderly exit: stop accepting input, cancel running work, let the engine finish (bounded wait),
    /// kill llama-server, then close windows and end the dispatcher.
    /// </summary>
    public async Task ExitAsync()
    {
        if (exiting) return;
        exiting = true;
        Log("exit requested");
        CancelJob();
        lifetime.Cancel();
        input.Dispose();
        tray.Dispose();
        try { await Translator.ShutdownAsync(TimeSpan.FromSeconds(5)); } catch (Exception ex) { LogError("shutdown", ex); }
        WindowsOcr.Dispose(); Tesseract.Dispose();
        settingsWindow?.Close();
        popup?.Close();
        // The last original/translation pair lives only in memory; drop it explicitly before exiting.
        LastSource = ""; LastTranslation = "";
        Log("exit complete");
        Application.Current.Exit();
    }
}
