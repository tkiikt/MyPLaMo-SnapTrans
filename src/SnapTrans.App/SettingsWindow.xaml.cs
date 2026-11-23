using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using SnapTrans.App.Native;
using SnapTrans.Core;
using SnapTrans.Llama;
using SnapTrans.Ocr.Tesseract;
using Windows.ApplicationModel.DataTransfer;

namespace SnapTrans.App;

public sealed partial class SettingsWindow : Window
{
    readonly AppHost host;
    AppSettings S => host.Settings;
    bool loading;
    readonly Dictionary<string, ModelRow> rows = [];
    CancellationTokenSource? download;
    string? downloadingId;
    static readonly string[] Themes = ["system", "light", "dark"];
    static readonly string[] UiLanguages = ["auto", "ja-JP", "en-US"];

    bool noModifiers;
    readonly HashSet<string> verifyingHere = [];

    /// <summary>Hashes models that are present but not verified yet (first time seen, or the file changed).</summary>
    async Task VerifyFolderAsync()
    {
        var store = new ModelStore(S.ModelFolder);
        foreach (var r in rows.Values) {
            if (store.StateOf(r.Model) != ModelState.Unverified) continue;
            if (r.Model.Id == S.ModelId) { await host.EnsureVerifiedAsync(preload: true); continue; }
            if (!verifyingHere.Add(r.Model.Id)) continue;
            Refresh();
            try { await Task.Run(() => store.VerifyAsync(r.Model, null, CancellationToken.None)); }
            catch (Exception ex) { AppHost.LogError($"verify {r.Model.Id}", ex); }
            finally { verifyingHere.Remove(r.Model.Id); }
        }
        Refresh();
    }

    sealed class ModelRow
    {
        public required ModelInfo Model;
        public required RadioButton Use;
        public required TextBlock State;
        public required ProgressBar Progress;
        public required Button Action, Cancel, Delete;
    }

    public SettingsWindow(AppHost host)
    {
        this.host = host;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarArea);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "SnapTrans.ico"));
        TitleIcon.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "SnapTrans-48.png")));
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        double scale = Win32.GetDpiForWindow(hwnd) / 96.0;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        int w = Math.Min((int)(900 * scale), area.Width), h = Math.Min((int)(900 * scale), area.Height);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h));
        loading = true;
        BuildModelRows();
        ModCtrl.IsChecked = S.Modifiers.HasFlag(SnapModifiers.Ctrl);
        ModAlt.IsChecked = S.Modifiers.HasFlag(SnapModifiers.Alt);
        ModShift.IsChecked = S.Modifiers.HasFlag(SnapModifiers.Shift);
        ModWin.IsChecked = S.Modifiers.HasFlag(SnapModifiers.Win);
        LicenseCheck.IsChecked = S.LicenseAccepted;
        loading = false;
        ApplyTheme();
        ApplyStrings();
        Root.ActualThemeChanged += (_, _) => UpdateCaption();
        Loc.Changed += OnLanguageChanged;
        host.StateChanged += Refresh;
        Closed += (_, _) => { Loc.Changed -= OnLanguageChanged; host.StateChanged -= Refresh; download?.Cancel(); };
        _ = RefreshDevicesAsync();
        _ = VerifyFolderAsync();
    }

    void OnLanguageChanged() { ModelStatus.Text = ""; ApplyStrings(); }

    public void ApplyTheme()
    {
        Root.RequestedTheme = host.ElementTheme;
        UpdateCaption();
    }

    void UpdateCaption()
    {
        bool dark = Root.ActualTheme == ElementTheme.Dark;
        AppWindow.TitleBar.PreferredTheme = dark ? TitleBarTheme.Dark : TitleBarTheme.Light;
    }

    void ApplyStrings()
    {
        loading = true;
        Title = WindowTitle.Text = Loc.T("Settings_Title");
        HeaderTitle.Text = Loc.T("AppName");
        HeaderSubtitle.Text = Loc.T("Settings_Subtitle");
        BuiltWith.Text = AboutBuilt.Text = Loc.T("BuiltWithPlamo");
        ModelTitle.Text = Loc.T("Sec_Model"); ModelDesc.Text = Loc.T("Model_Desc");
        LicenseLink.Content = AboutLicense.Content = Loc.T("License_Link");
        // The license page follows the display language (Japanese or English original), also right after switching.
        ToolTipService.SetToolTip(LicenseLink, Loc.LicenseUrl);
        ToolTipService.SetToolTip(AboutLicense, Loc.LicenseUrl);
        LicenseCheck.Content = Loc.T("License_Agree");
        FolderLabel.Text = Loc.T("Folder"); FolderOpenButton.Content = Loc.T("Folder_Open"); FolderChangeButton.Content = Loc.T("Folder_Change");
        FolderNote.Text = Loc.T("Folder_Note");
        DeviceTitle.Text = Loc.T("Sec_Device"); DeviceDesc.Text = Loc.T("Device_Desc"); DeviceRefresh.Content = Loc.T("Device_Refresh");
        CudaTitle.Text = Loc.T("Cuda_Title"); CudaDesc.Text = Loc.T("Cuda_Desc");
        ShortcutTitle.Text = Loc.T("Sec_Shortcut"); ShortcutDesc.Text = Loc.T("Shortcut_Desc"); ShortcutWarning.Text = Loc.T("Shortcut_Need");
        TranslationTitle.Text = Loc.T("Sec_Translation"); TargetDesc.Text = Loc.T("Target_Desc");
        ComboBoxHelper(TargetBox, Loc.T("Target"));
        OcrTitle.Text = Loc.T("Sec_Ocr"); OcrSettingsLink.Content = Loc.T("Ocr_OpenSettings"); OcrOpenSettingsButton.Content = Loc.T("Ocr_OpenSettings"); OcrAccuracyText.Text = Loc.T("Ocr_Accuracy"); TessButton.Content = Loc.T("Tess_Download");
        ComboBoxHelper(OcrEngineBox, Loc.T("Ocr_Engine")); ComboBoxHelper(OcrLanguageBox, Loc.T("Ocr_Language"));
        AppearanceTitle.Text = Loc.T("Sec_Appearance");
        ComboBoxHelper(UiLanguageBox, Loc.T("UiLanguage")); ComboBoxHelper(ThemeBox, Loc.T("Theme"));
        LastTitle.Text = Loc.T("Sec_Last"); LastNone.Text = Loc.T("Last_None");
        LastSourceLabel.Text = Loc.T("Last_Source"); LastResultLabel.Text = Loc.T("Last_Result");
        AboutTitle.Text = Loc.T("Sec_About");
        AboutText.Text = Loc.F("About_Text", typeof(App).Assembly.GetName().Version?.ToString(3));

        UiLanguageBox.ItemsSource = new[] { Loc.T("UiLanguage_Auto"), "日本語", "English" };
        UiLanguageBox.SelectedIndex = Math.Max(0, Array.IndexOf(UiLanguages, S.Language));
        ThemeBox.ItemsSource = new[] { Loc.T("Theme_System"), Loc.T("Theme_Light"), Loc.T("Theme_Dark") };
        ThemeBox.SelectedIndex = Math.Max(0, Array.IndexOf(Themes, S.Theme));
        var targets = new List<string> { Loc.T("Target_Auto") };
        targets.AddRange(TranslationLanguage.All.Select(l => l.Name(Loc.Japanese)));
        TargetBox.ItemsSource = targets;
        var ti = TranslationLanguage.All.ToList().FindIndex(l => l.Id == S.Target);
        TargetBox.SelectedIndex = ti < 0 ? 0 : ti + 1;
        OcrEngineBox.ItemsSource = new[] { Loc.T("Ocr_Windows"), Loc.T("Ocr_Tesseract") };
        OcrEngineBox.SelectedIndex = S.OcrEngine == "tesseract" ? 1 : 0;
        foreach (var r in rows.Values) {
            r.Action.Content = Loc.T("Model_Download"); r.Cancel.Content = Loc.T("Model_Cancel"); r.Delete.Content = Loc.T("Model_Delete");
        }
        loading = false;
        FillOcrLanguages();
        FillDevices();
        Refresh();
    }

    static void ComboBoxHelper(ComboBox box, string header) => box.Header = header;

    // ---------------- Models ----------------
    void BuildModelRows()
    {
        foreach (var m in ModelInfo.Catalog.Where(m => m.Id is "0.8b" or "2b" or "8b" or "31b")) {
            var grid = new Grid { ColumnSpacing = 8 };
            foreach (var w in new[] { new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto, GridLength.Auto })
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = w });
            var info = new StackPanel { Spacing = 2 };
            var use = new RadioButton { GroupName = "Model", Content = $"{m.DisplayName}　·　{Loc.Size(m.Bytes)}", Tag = m.Id, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(use, "Use_" + m.Id);
            use.Checked += Use_Checked;
            var state = new TextBlock { Style = (Style)Application.Current.Resources["Note"], Margin = new Thickness(28, 0, 0, 0) };
            var progress = new ProgressBar { Maximum = 1, Visibility = Visibility.Collapsed, Margin = new Thickness(28, 4, 0, 0) };
            info.Children.Add(use); info.Children.Add(state); info.Children.Add(progress);
            var action = new Button { Tag = m.Id, VerticalAlignment = VerticalAlignment.Center };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(action, "Download_" + m.Id);
            action.Click += Download_Click;
            var cancel = new Button { Tag = m.Id, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
            cancel.Click += (_, _) => download?.Cancel();
            var delete = new Button { Tag = m.Id, VerticalAlignment = VerticalAlignment.Center };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(delete, "Delete_" + m.Id);
            delete.Click += Delete_Click;
            Grid.SetColumn(action, 1); Grid.SetColumn(cancel, 2); Grid.SetColumn(delete, 3);
            grid.Children.Add(info); grid.Children.Add(action); grid.Children.Add(cancel); grid.Children.Add(delete);
            ModelRows.Children.Add(new Border { Child = grid, Style = (Style)Application.Current.Resources["ModelRowStyle"] });
            rows[m.Id] = new ModelRow { Model = m, Use = use, State = state, Progress = progress, Action = action, Cancel = cancel, Delete = delete };
        }
    }

    void Refresh()
    {
        var store = new ModelStore(S.ModelFolder);
        FolderText.Text = S.ModelFolder;
        ToolTipService.SetToolTip(FolderText, S.ModelFolder);
        loading = true;
        foreach (var r in rows.Values) {
            var st = store.StateOf(r.Model);
            bool busy = downloadingId == r.Model.Id;
            bool verifying = host.Verifying.Contains(r.Model.Id) || verifyingHere.Contains(r.Model.Id);
            bool changing = host.EngineChanging;
            bool usable = st is ModelState.Ready or ModelState.Outdated;
            r.Use.IsEnabled = usable && downloadingId == null && !changing;
            r.Use.IsChecked = S.ModelId == r.Model.Id && usable;
            if (!busy) {
                var inUse = S.ModelId == r.Model.Id;
                r.State.Text = (verifying ? Loc.T("Model_VerifyingExisting") : st switch {
                    ModelState.Ready => inUse ? Loc.T("Model_InUse") : Loc.T("Model_Ready"),
                    // An older official file (e.g. downloaded by another app before PFN updated the chat template).
                    ModelState.Outdated => Loc.F("Model_Outdated", store.VersionOf(r.Model)?.Date ?? "?") + (inUse ? " · " + Loc.T("Model_InUse") : ""),
                    ModelState.Partial => Loc.F("Model_Partial", Loc.Size(store.PartialBytes(r.Model))),
                    ModelState.Unverified => Loc.T("Model_Unverified"),
                    ModelState.Corrupt => Loc.T("Model_Corrupt"),
                    _ => Loc.T("Model_Missing")
                }) + (r.Model.Id == "8b" ? " · " + Loc.T("Model_Large") : r.Model.Id == "31b" ? " · " + Loc.T("Model_Huge") : "");
                // Clearing the local value lets the theme-aware Note style apply (light and dark); corrupt files are shown in red.
                if (st == ModelState.Corrupt && !verifying) r.State.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0xE8, 0x4A, 0x4A));
                else r.State.ClearValue(TextBlock.ForegroundProperty);
                r.Progress.Visibility = verifying ? Visibility.Visible : Visibility.Collapsed;
                r.Progress.IsIndeterminate = verifying;
            }
            r.Action.Content = Loc.T(st switch { ModelState.Partial => "Model_Resume", ModelState.Corrupt => "Model_Redownload", ModelState.Outdated => "Model_Update", _ => "Model_Download" });
            r.Action.Visibility = st is ModelState.Ready or ModelState.Unverified || busy ? Visibility.Collapsed : Visibility.Visible;
            r.Action.IsEnabled = downloadingId == null && !changing && !verifying;
            r.Cancel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            r.Delete.IsEnabled = st != ModelState.Missing && !busy && !changing && !verifying;
        }
        loading = false;
        FolderChangeButton.IsEnabled = downloadingId == null && !host.EngineChanging;
        DeviceBox.IsEnabled = !host.EngineChanging;
        CudaButton.IsEnabled = !host.EngineChanging && !cudaBusy;
        EngineBusyPanel.Visibility = host.EngineChanging ? Visibility.Visible : Visibility.Collapsed;
        EngineBusyText.Text = Loc.T("Engine_Changing");
        ModelBusyPanel.Visibility = host.EngineChanging ? Visibility.Visible : Visibility.Collapsed;
        ModelBusyText.Text = Loc.T("Engine_Changing");
        ShortcutWarning.Visibility = host.HookError != null || noModifiers ? Visibility.Visible : Visibility.Collapsed;
        ShortcutWarning.Text = host.AnotherInstanceOwnsHooks ? Loc.T("Hook_OtherInstance") : host.HookError != null ? Loc.F("Hook_FailedDetail", host.HookError) : Loc.T("Shortcut_Need");
        var loaded = host.Translator.Loaded;
        DeviceCurrent.Text = loaded == null ? Loc.T("Device_NotLoaded")
            : Loc.F("Device_Current", $"{loaded.Device.Label} · {Path.GetFileName(loaded.ModelPath)}")
              + (loaded.FallbackReason is { } reason ? "\n" + Loc.F("Fallback", AppHost.ReasonText(reason)) : "");
        bool cuda = Directory.Exists(Path.Combine(AppSettings.EngineRoot, "cuda"));
        CudaState.Text = Loc.T(cuda ? "Cuda_Installed" : "Cuda_NotInstalled");
        CudaButton.Content = Loc.T(cuda ? "Cuda_Remove" : "Cuda_Install");
        ShortcutPreview.Text = AppHost.ShortcutText(S.Modifiers) + " + " + (Loc.Japanese ? "左ドラッグ" : "left-drag");
        LastNone.Visibility = host.LastSource.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        LastGrid.Visibility = host.LastSource.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        LastSource.Text = host.LastSource; LastResult.Text = host.LastTranslation;
    }

    void License_Changed(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        S.LicenseAccepted = LicenseCheck.IsChecked == true; S.Save();
    }

    async void Download_Click(object sender, RoutedEventArgs e)
    {
        var id = (string)((Button)sender).Tag;
        if (!S.LicenseAccepted) { ModelStatus.Text = Loc.T("License_Required"); LicenseCheck.Focus(FocusState.Programmatic); return; }
        var row = rows[id];
        ModelStatus.Text = "";
        var downloadStore = new ModelStore(S.ModelFolder);
        var before = downloadStore.StateOf(row.Model);
        // Writing into the folder (which may belong to another app) only happens after an explicit confirmation.
        var key = before switch { ModelState.Corrupt => "Confirm_Redownload", ModelState.Outdated => "Confirm_Update", _ => "Confirm_Download" };
        if (!await ConfirmAsync(Loc.F(key + "_Title", row.Model.DisplayName), Loc.F(key + "_Body", S.ModelFolder, Loc.Size(row.Model.Bytes)), Loc.T("Model_" + (before == ModelState.Outdated ? "Update" : "Download")))) return;
        if (before == ModelState.Corrupt) {
            if (S.ModelId == id) await host.ApplyEngineChangeAsync(null, preload: false);
            try { downloadStore.Delete(row.Model); } catch (Exception ex) { ModelStatus.Text = Loc.Error(ex); return; }
        }
        // The old file stays usable until the new one is verified; the engine releases it just before the swap.
        download = new CancellationTokenSource();
        downloadingId = id;
        Refresh();
        row.Progress.Visibility = Visibility.Visible;
        var progress = new Progress<DownloadProgress>(p => {
            row.Progress.IsIndeterminate = p.Phase != DownloadPhase.Downloading;
            row.Progress.Value = p.Fraction;
            row.State.Text = p.Phase switch {
                DownloadPhase.Downloading => Loc.F("Model_Progress", row.Model.DisplayName, p.Fraction * 100, Loc.Size(p.Received), Loc.Size(p.Total), p.BytesPerSecond / 1e6),
                DownloadPhase.Verifying => Loc.T("Model_Verifying"),
                DownloadPhase.Connecting => Loc.T("Model_Connecting"),
                _ => row.State.Text
            };
        });
        try {
            if (before == ModelState.Outdated) {
                var store = new ModelStore(S.ModelFolder);
                await DownloadToTempAndSwapAsync(store, row.Model, progress, download.Token);
            } else {
                await new ModelStore(S.ModelFolder).DownloadAsync(row.Model, progress, download.Token);
            }
            ModelStatus.Text = Loc.F("Model_Downloaded", row.Model.DisplayName);
            if (host.ActiveModel == null) await SelectModelAsync(id);
            else if (S.ModelId == id) await host.ApplyEngineChangeAsync(null);
        } catch (OperationCanceledException) {
            ModelStatus.Text = Loc.T("Model_Paused");
        } catch (Exception ex) {
            ModelStatus.Text = Loc.Error(ex);
            AppHost.LogError("download", ex);
        } finally {
            downloadingId = null; download = null;
            Refresh();
        }
    }

    async Task DownloadToTempAndSwapAsync(ModelStore store, ModelInfo m, IProgress<DownloadProgress> progress, CancellationToken ct)
    {
        // llama-server keeps the model memory-mapped: stop it before the verified download replaces the file.
        if (S.ModelId == m.Id) await host.ApplyEngineChangeAsync(null, preload: false);
        await store.DownloadAsync(m, progress, ct, replaceExisting: true);
    }

    async Task<bool> ConfirmAsync(string title, string body, string primary)
    {
        var dialog = new ContentDialog {
            XamlRoot = Root.XamlRoot, Title = title, Content = new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = primary, CloseButtonText = Loc.T("Cancel"), DefaultButton = ContentDialogButton.Close,
            RequestedTheme = Root.ActualTheme
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    async void Use_Checked(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        await SelectModelAsync((string)((RadioButton)sender).Tag);
    }

    async Task SelectModelAsync(string id)
    {
        if (S.ModelId == id && host.Translator.Loaded != null) return;
        await host.ApplyEngineChangeAsync(() => S.ModelId = id);
        ModelStatus.Text = Loc.F("Model_Selected", ModelInfo.Find(id)?.DisplayName);
    }

    async void Delete_Click(object sender, RoutedEventArgs e)
    {
        var id = (string)((Button)sender).Tag;
        var m = rows[id].Model;
        if (!await ConfirmAsync(Loc.F("Model_DeleteConfirm", m.DisplayName), Loc.F("Confirm_Delete_Body", new ModelStore(S.ModelFolder).PathOf(m)), Loc.T("Model_Delete"))) return;
        try {
            // The engine may still be loading or translating with this file: stop it asynchronously first.
            if (S.ModelId == id) await host.ApplyEngineChangeAsync(() => S.ModelId = "", preload: false);
            new ModelStore(S.ModelFolder).Delete(m);
            ModelStatus.Text = Loc.F("Model_Deleted", m.DisplayName);
        } catch (Exception ex) { ModelStatus.Text = Loc.Error(ex); }
        Refresh();
    }

    async void FolderChange_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(AppWindow.Id) { CommitButtonText = Loc.T("Folder_Pick") };
        var picked = await picker.PickSingleFolderAsync();
        if (picked?.Path is not { Length: > 0 } path) return;
        await host.ApplyEngineChangeAsync(() => {
            S.ModelFolder = path;
            // Keep the selected model if the new folder has it; otherwise use whatever valid model is there.
            var store = new ModelStore(path);
            var current = ModelInfo.Find(S.ModelId);
            if (current == null || store.StateOf(current) is ModelState.Missing or ModelState.Partial or ModelState.Corrupt) {
                var found = ModelInfo.Catalog.FirstOrDefault(m => store.StateOf(m) is ModelState.Ready or ModelState.Outdated or ModelState.Unverified);
                S.ModelId = found?.Id ?? S.ModelId;
            }
        });
        _ = VerifyFolderAsync();
    }

    void FolderOpen_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(S.ModelFolder);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{S.ModelFolder}\"") { UseShellExecute = false });
    }

    // ---------------- Device ----------------
    async Task RefreshDevicesAsync()
    {
        DeviceFound.Text = Loc.T("Device_Scanning");
        DeviceRefresh.IsEnabled = false;
        try { host.Devices = await host.Engines.DiscoverAsync(CancellationToken.None); }
        catch (Exception ex) { AppHost.LogError("devices", ex); }
        DeviceRefresh.IsEnabled = true;
        FillDevices();
    }

    void FillDevices()
    {
        loading = true;
        var items = new List<(string Key, string Label)> { ("auto", Loc.T("Device_Auto")), ("cpu", Loc.T("Device_Cpu")) };
        foreach (var d in host.Devices?.Devices ?? []) items.Add((d.Key, d.Label + (d.Integrated ? (Loc.Japanese ? "（内蔵）" : " (integrated)") : "")));
        if (!items.Any(i => i.Key == S.Device)) items.Add((S.Device, S.DeviceLabel.Length > 0 ? S.DeviceLabel : S.Device));
        DeviceBox.ItemsSource = items.Select(i => i.Label).ToList();
        DeviceBox.Tag = items.Select(i => i.Key).ToList();
        DeviceBox.SelectedIndex = items.FindIndex(i => i.Key == S.Device);
        if (host.Devices != null)
            DeviceFound.Text = host.Devices.Devices.Count == 0 ? Loc.T("Device_None") : Loc.F("Device_Found", string.Join(", ", host.Devices.Devices.Select(d => d.Label)));
        loading = false;
    }

    void Device_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loading || DeviceBox.SelectedIndex < 0 || DeviceBox.Tag is not List<string> keys) return;
        var key = keys[DeviceBox.SelectedIndex];
        if (key == S.Device) return;
        var label = (string)DeviceBox.SelectedItem;
        _ = host.ApplyEngineChangeAsync(() => { S.Device = key; S.DeviceLabel = label; });
    }

    void DeviceRefresh_Click(object sender, RoutedEventArgs e) => _ = RefreshDevicesAsync();

    bool cudaBusy;

    async void Cuda_Click(object sender, RoutedEventArgs e)
    {
        cudaBusy = true;
        CudaButton.IsEnabled = false;
        try {
            if (Directory.Exists(Path.Combine(AppSettings.EngineRoot, "cuda"))) {
                // Stop a CUDA server (or a load that may pick CUDA) before deleting its files.
                await host.ApplyEngineChangeAsync(() => { }, preload: false);
                CudaEngineInstaller.Uninstall(AppSettings.EngineRoot);
                host.Preload();
            } else {
                CudaProgress.Visibility = Visibility.Visible;
                await CudaEngineInstaller.InstallAsync(AppSettings.EngineRoot, Path.Combine(AppContext.BaseDirectory, "engine", "vulkan", "LICENSE-llama.cpp"), Path.Combine(AppContext.BaseDirectory, "engine", "vulkan"), new Progress<DownloadProgress>(p => {
                    CudaProgress.IsIndeterminate = p.Phase != DownloadPhase.Downloading || p.Total <= 0;
                    CudaProgress.Value = p.Fraction;
                    CudaState.Text = p.Phase == DownloadPhase.Downloading ? $"{Loc.Size(p.Received)} / {Loc.Size(p.Total)}" : Loc.T("Model_Verifying");
                }), CancellationToken.None);
            }
        } catch (Exception ex) { CudaState.Text = Loc.Error(ex); AppHost.LogError("cuda", ex); }
        CudaProgress.Visibility = Visibility.Collapsed;
        cudaBusy = false;
        CudaButton.IsEnabled = true;
        Refresh();
        await RefreshDevicesAsync();
    }

    // ---------------- Shortcut ----------------
    void Modifier_Click(object sender, RoutedEventArgs e)
    {
        var m = SnapModifiers.None;
        if (ModCtrl.IsChecked == true) m |= SnapModifiers.Ctrl;
        if (ModAlt.IsChecked == true) m |= SnapModifiers.Alt;
        if (ModShift.IsChecked == true) m |= SnapModifiers.Shift;
        if (ModWin.IsChecked == true) m |= SnapModifiers.Win;
        noModifiers = m == SnapModifiers.None;
        Refresh();
        if (noModifiers) return;
        S.Modifiers = m; S.Save();
        host.ApplyModifiers();
        Refresh();
    }

    // ---------------- Translation / OCR ----------------
    void Target_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loading || TargetBox.SelectedIndex < 0) return;
        S.Target = TargetBox.SelectedIndex == 0 ? "auto" : TranslationLanguage.All[TargetBox.SelectedIndex - 1].Id;
        S.Save();
    }

    void OcrEngine_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loading || OcrEngineBox.SelectedIndex < 0) return;
        S.OcrEngine = OcrEngineBox.SelectedIndex == 1 ? "tesseract" : "windows";
        S.OcrLanguage = ""; S.Save();
        FillOcrLanguages();
    }

    void FillOcrLanguages()
    {
        loading = true;
        bool tess = S.OcrEngine == "tesseract";
        var langs = tess ? host.Tesseract.AvailableLanguages : host.WindowsOcr.AvailableLanguages;
        var items = new List<string> { Loc.T("Ocr_Auto") };
        items.AddRange(langs.Select(l => $"{l.DisplayName} ({l.Tag})"));
        OcrLanguageBox.ItemsSource = items;
        OcrLanguageBox.Tag = langs.Select(l => l.Tag).ToList();
        var idx = langs.ToList().FindIndex(l => l.Tag == S.OcrLanguage);
        OcrLanguageBox.SelectedIndex = idx < 0 ? 0 : idx + 1;
        OcrInstalled.Text = Loc.F("Ocr_Installed", langs.Count == 0 ? "—" : string.Join(", ", langs.Select(l => l.Tag)));
        var missing = new List<string>();
        if (!langs.Any(l => l.Tag.StartsWith("ja", StringComparison.OrdinalIgnoreCase))) missing.Add(Loc.Japanese ? "日本語" : "Japanese");
        if (!langs.Any(l => l.Tag.StartsWith("en", StringComparison.OrdinalIgnoreCase))) missing.Add(Loc.Japanese ? "英語" : "English");
        OcrHelpPanel.Visibility = !tess && missing.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        OcrAccuracyPanel.Visibility = tess ? Visibility.Collapsed : Visibility.Visible;
        OcrHelp.Text = Loc.F("Ocr_MissingHelp", string.Join(Loc.Japanese ? "・" : ", ", missing));
        TessPanel.Visibility = tess ? Visibility.Visible : Visibility.Collapsed;
        TessState.Text = langs.Count == 2 ? Loc.F("Tess_Ready", "eng, jpn") : Loc.T("Tess_Missing");
        TessButton.Visibility = tess && langs.Count < 2 ? Visibility.Visible : Visibility.Collapsed;
        loading = false;
    }

    void OcrLanguage_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loading || OcrLanguageBox.SelectedIndex < 0 || OcrLanguageBox.Tag is not List<string> tags) return;
        S.OcrLanguage = OcrLanguageBox.SelectedIndex == 0 ? "" : tags[OcrLanguageBox.SelectedIndex - 1];
        S.Save();
    }

    // Opens Windows Settings → Time & language → Language & region. Only the user changes anything there.
    /// <summary>Test switch: log the license URL instead of opening the browser (GUI tests on a shared desktop).</summary>
    static bool DebugNoLaunch => Environment.GetEnvironmentVariable("SNAPTRANS_DEBUG_NO_LAUNCH") == "1";

    async void License_Click(object sender, RoutedEventArgs e)
    {
        var url = Loc.LicenseUrl; // read at click time: always the current display language
        AppHost.Log($"open license link ({(Loc.Japanese ? "ja" : "en")}): {url}");
        if (!DebugNoLaunch) await Windows.System.Launcher.LaunchUriAsync(new Uri(url));
    }

    async void OcrOpenSettings_Click(object sender, RoutedEventArgs e) =>
        await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:regionlanguage"));

    async void Tess_Click(object sender, RoutedEventArgs e)
    {
        TessButton.IsEnabled = false;
        try {
            foreach (var code in new[] { "eng", "jpn" })
                if (!File.Exists(Path.Combine(AppSettings.TessdataFolder, code + ".traineddata")))
                    await TesseractOcr.DownloadAsync(AppSettings.TessdataFolder, code, CancellationToken.None);
        } catch (Exception ex) { TessState.Text = Loc.Error(ex); }
        TessButton.IsEnabled = true;
        FillOcrLanguages();
    }

    // ---------------- Appearance ----------------
    void UiLanguage_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loading || UiLanguageBox.SelectedIndex < 0) return;
        S.Language = UiLanguages[UiLanguageBox.SelectedIndex]; S.Save();
        Loc.Set(S.Language);
    }

    void Theme_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (loading || ThemeBox.SelectedIndex < 0) return;
        S.Theme = Themes[ThemeBox.SelectedIndex]; S.Save();
        host.ApplyTheme();
    }

    void LastSourceCopy_Click(object sender, RoutedEventArgs e) => Copy(host.LastSource);
    void LastResultCopy_Click(object sender, RoutedEventArgs e) => Copy(host.LastTranslation);
    static void Copy(string text)
    {
        if (text.Length == 0) return;
        var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); Clipboard.Flush();
    }
}
