using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using SnapTrans.App.Native;
using Windows.ApplicationModel.DataTransfer;
using Windows.UI;
using static SnapTrans.App.Native.Win32;

namespace SnapTrans.App;

/// <summary>Result card: dark navy rounded card (light variant in light theme), copy, original/translation toggle, ×, drag to move.</summary>
public sealed partial class PopupWindow : Window
{
    readonly nint hwnd;
    string translation = "", source = "";
    bool showingSource, closed;
    RECT anchor;
    public bool IsClosed => closed;

    public PopupWindow()
    {
        InitializeComponent();
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Title = "MyPLaMo SnapTrans";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "SnapTrans.ico"));
        var presenter = OverlappedPresenter.Create();
        presenter.SetBorderAndTitleBar(false, false);
        presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        int round = 2; DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
        // The borderless presenter keeps WS_DLGFRAME (needed for the DWM shadow), which leaves a 2-3 px light
        // non-client frame between the DWM outline and the XAML card. Make the client area cover the whole window
        // so the card reaches the rounded outline on every side; DWM still clips and outlines the same shape.
        ncProc = NcProc;
        SetWindowSubclass(hwnd, ncProc, 0x5354, 0);
        SetWindowPos(hwnd, 0, 0, 0, 0, 0, 0x1 | 0x2 | 0x4 | 0x10 | 0x20 /* NOSIZE|NOMOVE|NOZORDER|NOACTIVATE|FRAMECHANGED */);
        // Visible to screen capture (Win+Shift+S etc.). It cannot leak into SnapTrans' own OCR: the card is hidden
        // when a new drag starts and again, synchronously, right before the selection is captured.
        SetWindowDisplayAffinity(hwnd, WDA_NONE);
        Closed += (_, _) => closed = true;
        AppWindow.Closing += (_, e) => { e.Cancel = true; Hide(); };
        Root.ActualThemeChanged += (_, _) => ApplyColors();
        ApplyTheme();
        ApplyStrings();
    }

    public void ApplyTheme()
    {
        Root.RequestedTheme = App.Host?.ElementTheme ?? ElementTheme.Default;
        ApplyColors();
    }

    void ApplyColors()
    {
        bool dark = Root.ActualTheme == ElementTheme.Dark;
        Color bg = dark ? Color.FromArgb(255, 39, 50, 66) : Color.FromArgb(255, 248, 250, 253);
        Color title = dark ? Color.FromArgb(255, 190, 201, 217) : Color.FromArgb(255, 52, 66, 86);
        Color status = dark ? Color.FromArgb(255, 140, 154, 175) : Color.FromArgb(255, 104, 116, 134);
        Color body = dark ? Colors.White : Color.FromArgb(255, 26, 30, 36);
        Root.Background = new SolidColorBrush(bg);
        TitleText.Foreground = new SolidColorBrush(title);
        StatusText.Foreground = NoteText.Foreground = new SolidColorBrush(status);
        BodyText.Foreground = new SolidColorBrush(body);
        foreach (var b in new[] { SourceButton, CopyButton, CloseButton }) b.Foreground = new SolidColorBrush(title);
        AppWindow.TitleBar.BackgroundColor = bg;
        // DWM clips the window to its rounded corners and draws the 1 px border on the same rounded path, so the card
        // and its outline always share one radius at any DPI. The default border is a light grey that reads as a
        // white ring around the navy card; tint it tone-on-tone instead (a slightly lighter navy / a soft grey).
        Color edge = dark ? Color.FromArgb(255, 58, 72, 92) : Color.FromArgb(255, 214, 221, 230);
        int colorRef = edge.R | (edge.G << 8) | (edge.B << 16);
        DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, ref colorRef, sizeof(int));
    }

    /// <summary>
    /// Physical size whose DIP equivalent is a whole number (e.g. a multiple of 3 px at 150 %). XAML lays out in DIPs;
    /// with a fractional size the island stops one pixel short and the window's white background shows as a hairline.
    /// </summary>
    static int SnapToDip(double px, double scale)
    {
        int p = (int)Math.Ceiling(px);
        for (int i = 0; i < 8; i++, p++)
            if (Math.Abs(p / scale - Math.Round(p / scale)) < 0.001) return p;
        return (int)Math.Ceiling(px);
    }

    public void ApplyStrings()
    {
        TitleText.Text = Loc.T(showingSource ? "Popup_TitleSource" : "Popup_Title");
        ToolTipService.SetToolTip(CopyButton, Loc.T("Popup_Copy"));
        ToolTipService.SetToolTip(CloseButton, Loc.T("Popup_Close"));
        ToolTipService.SetToolTip(SourceButton, Loc.T(showingSource ? "Popup_ShowTranslation" : "Popup_ShowSource"));
        AutomationPropertiesHelper(CopyButton, Loc.T("Popup_Copy"));
        AutomationPropertiesHelper(CloseButton, Loc.T("Popup_Close"));
        AutomationPropertiesHelper(SourceButton, Loc.T(showingSource ? "Popup_ShowTranslation" : "Popup_ShowSource"));
    }

    static void AutomationPropertiesHelper(DependencyObject o, string name) => Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(o, name);

    /// <summary>Shows the card next to a physical-pixel selection rectangle.</summary>
    public void ShowAt(RECT selection, string stage)
    {
        anchor = selection;
        translation = source = ""; showingSource = false;
        SourceButton.IsEnabled = CopyButton.IsEnabled = false;
        BodyText.Text = ""; NoteText.Visibility = Visibility.Collapsed; SetWarning(null);
        Busy.Visibility = Visibility.Visible;
        StatusText.Text = stage;
        ApplyStrings();
        Fit(reposition: true);
        if (!AppWindow.IsVisible) AppWindow.Show(false);
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, 0x1 | 0x2 | SWP_NOACTIVATE); // keep above everything
    }

    public void SetStage(string stage) => StatusText.Text = stage;

    /// <summary>A small warning icon next to the model size; the message is in its tooltip (and accessible name).</summary>
    void SetWarning(string? message)
    {
        WarningIcon.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(WarningIcon, string.IsNullOrEmpty(message) ? null : message);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(WarningIcon, message ?? "");
    }

    public void SetResult(string translated, string original, string status, string? note)
    {
        translation = translated; source = original; showingSource = false;
        Busy.Visibility = Visibility.Collapsed;
        BodyText.Text = translated;
        StatusText.Text = status;
        SetWarning(note);
        SourceButton.IsEnabled = original.Length > 0; CopyButton.IsEnabled = true;
        ApplyStrings();
        Fit(reposition: false);
    }

    public void SetError(string message, string original)
    {
        source = original; translation = "";
        Busy.Visibility = Visibility.Collapsed;
        BodyText.Text = message;
        StatusText.Text = "";
        NoteText.Visibility = Visibility.Collapsed;
        SourceButton.IsEnabled = original.Length > 0; CopyButton.IsEnabled = original.Length > 0;
        Fit(reposition: false);
    }

    public void Hide()
    {
        AppWindow.Hide();
    }

    static (RECT Work, double Scale) MonitorOf(RECT r)
    {
        var monitor = MonitorFromRect(ref r, 2 /* NEAREST */);
        var info = new MONITORINFOEX { cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<MONITORINFOEX>(), szDevice = "" };
        GetMonitorInfo(monitor, ref info);
        return (info.rcWork, ScaleForMonitor(monitor));
    }

    /// <summary>
    /// Sizes the card for its content. A new card goes next to the selection (that monitor's DPI); an existing card
    /// is measured with the DPI of the monitor it is on now, so moving it to a screen with another scale keeps the
    /// text fitting.
    /// </summary>
    void Fit(bool reposition)
    {
        var pos = AppWindow.Position;
        var size = AppWindow.Size;
        var current = new RECT(pos.X, pos.Y, pos.X + Math.Max(1, size.Width), pos.Y + Math.Max(1, size.Height));
        var (work, scale) = MonitorOf(reposition ? anchor : current);
        double basis = reposition ? anchor.Width : size.Width / Math.Max(0.5, lastScale) * scale;
        int width = SnapToDip(Math.Clamp(basis, 380 * scale, Math.Max(380 * scale, Math.Min(720 * scale, work.Width - 16))), scale);
        double widthDip = width / scale;
        Root.Measure(new Windows.Foundation.Size(widthDip, double.PositiveInfinity));
        double desired = Header.DesiredSize.Height + BodyScroll.DesiredSize.Height;
        if (desired < 40) desired = 140;
        int height = SnapToDip(Math.Min(Math.Max(desired, 96) * scale + 8 * scale, work.Height * 0.7), scale);
        int x = pos.X, y = pos.Y;
        if (reposition) {
            int gap = (int)(10 * scale);
            x = anchor.Left;
            y = anchor.Bottom + gap;
            if (y + height > work.Bottom) y = anchor.Top - gap - height;
            if (y < work.Top) y = Math.Max(work.Top, work.Bottom - height);
        } else if (y + height > work.Bottom) {
            y = Math.Max(work.Top, work.Bottom - height); // grow downward but stay on this monitor
        }
        x = Math.Clamp(x, work.Left, Math.Max(work.Left, work.Right - width));
        lastScale = scale;
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, width, height));
    }

    double lastScale = 1;

    delegate nint SubclassProc(nint hwnd, uint msg, nuint wParam, nint lParam, nuint id, nuint data);
    SubclassProc? ncProc;
    static nint NcProc(nint hwnd, uint msg, nuint wParam, nint lParam, nuint id, nuint data)
    {
        // WM_NCCALCSIZE with wParam = TRUE: returning 0 keeps the proposed rectangle (= the window) as the client area.
        if (msg == 0x0083 && wParam != 0) return 0;
        return DefSubclassProc(hwnd, msg, wParam, lParam);
    }
    [System.Runtime.InteropServices.DllImport("comctl32")] static extern bool SetWindowSubclass(nint hwnd, SubclassProc proc, nuint id, nuint data);
    [System.Runtime.InteropServices.DllImport("comctl32")] static extern nint DefSubclassProc(nint hwnd, uint msg, nuint wParam, nint lParam);

    void Copy_Click(object sender, RoutedEventArgs e)
    {
        var text = showingSource ? source : translation.Length > 0 ? translation : source;
        if (text.Length == 0) return;
        var data = new DataPackage(); data.SetText(text);
        Clipboard.SetContent(data); Clipboard.Flush();
        CopyIcon.Glyph = "";
        ToolTipService.SetToolTip(CopyButton, Loc.T("Popup_Copied"));
        var timer = DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromSeconds(1.5); timer.IsRepeating = false;
        timer.Tick += (_, _) => { CopyIcon.Glyph = ""; ToolTipService.SetToolTip(CopyButton, Loc.T("Popup_Copy")); };
        timer.Start();
    }

    void Source_Click(object sender, RoutedEventArgs e)
    {
        if (source.Length == 0) return;
        showingSource = !showingSource;
        BodyText.Text = showingSource ? source : translation.Length > 0 ? translation : BodyText.Text;
        ApplyStrings();
        Fit(reposition: false);
    }

    void Close_Click(object sender, RoutedEventArgs e) => Hide();

    void Root_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape) { Hide(); e.Handled = true; }
    }

    void Root_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(Root).Properties.IsLeftButtonPressed) return;
        // Follow the cursor while the left button is held. Polling the cursor (physical pixels) keeps
        // working across monitors with different DPI and does not depend on pointer capture.
        e.Handled = true;
        GetCursorPos(out var start);
        var origin = AppWindow.Position;
        dragTimer?.Stop();
        dragTimer = DispatcherQueue.CreateTimer();
        dragTimer.Interval = TimeSpan.FromMilliseconds(8);
        dragTimer.Tick += (t, _) => {
            if (GetAsyncKeyState(0x01) >= 0) {
                t.Stop();
                // Dropped on a monitor with a different scale: re-measure with that DPI.
                var p2 = AppWindow.Position; var s2 = AppWindow.Size;
                if (Math.Abs(MonitorOf(new RECT(p2.X, p2.Y, p2.X + s2.Width, p2.Y + s2.Height)).Scale - lastScale) > 0.01) Fit(reposition: false);
                return;
            }
            GetCursorPos(out var now);
            AppWindow.Move(new Windows.Graphics.PointInt32(origin.X + now.X - start.X, origin.Y + now.Y - start.Y));
        };
        dragTimer.Start();
    }

    Microsoft.UI.Dispatching.DispatcherQueueTimer? dragTimer;
    void Root_PointerMoved(object sender, PointerRoutedEventArgs e) { }
    void Root_PointerReleased(object sender, PointerRoutedEventArgs e) { }
    void Root_PointerCaptureLost(object sender, PointerRoutedEventArgs e) { }
}
