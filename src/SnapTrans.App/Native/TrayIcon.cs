using System.Runtime.InteropServices;
using Microsoft.Win32;
using static SnapTrans.App.Native.Win32;

namespace SnapTrans.App.Native;

/// <summary>
/// Shell_NotifyIcon on a hidden window owned by the UI thread.
/// The icon follows the taskbar theme (SystemUsesLightTheme): a dark glyph on a light taskbar and a light glyph on a
/// dark one. It is swapped when Windows broadcasts WM_SETTINGCHANGE "ImmersiveColorSet", and reloaded at the right
/// size when Explorer restarts (TaskbarCreated) or the DPI changes.
/// </summary>
sealed class TrayIcon : IDisposable
{
    const uint CallbackMessage = WM_APP + 0x40;
    const uint WM_SETTINGCHANGE = 0x001A;
    readonly WndProc proc;
    readonly nint hwnd;
    readonly uint taskbarCreated;
    readonly string lightTaskbarIcon, darkTaskbarIcon;
    NOTIFYICONDATA data;
    public Func<IReadOnlyList<(uint Id, string? Text, bool Checked)>>? MenuItems;
    public event Action<uint>? Command;
    public event Action? Activated;
    /// <summary>Raised after the icon was (re)loaded: true = light taskbar.</summary>
    public event Action<bool>? ThemeApplied;
    public bool LightTaskbar { get; private set; }

    /// <summary>
    /// Test switch: read "light"/"dark" from this file instead of the registry, so theme following can be verified
    /// without touching the owner's Windows settings (then broadcast-equivalent WM_SETTINGCHANGE to this window).
    /// </summary>
    static string? DebugThemeFile => Environment.GetEnvironmentVariable("SNAPTRANS_DEBUG_TRAY_THEME_FILE");

    /// <param name="lightTaskbarIcon">ICO drawn for a light taskbar (dark glyph).</param>
    /// <param name="darkTaskbarIcon">ICO drawn for a dark taskbar (light glyph).</param>
    public TrayIcon(string lightTaskbarIcon, string darkTaskbarIcon, string tip)
    {
        this.lightTaskbarIcon = lightTaskbarIcon; this.darkTaskbarIcon = darkTaskbarIcon;
        proc = Proc;
        var instance = GetModuleHandle(null);
        var cls = new WNDCLASSEX { cbSize = (uint)Marshal.SizeOf<WNDCLASSEX>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc), hInstance = instance, lpszClassName = "SnapTrans.Tray" };
        RegisterClassEx(ref cls);
        // Top-level (not message-only) so broadcasts such as WM_SETTINGCHANGE and TaskbarCreated arrive.
        hwnd = CreateWindowEx(WS_EX_TOOLWINDOW, "SnapTrans.Tray", "SnapTrans.Tray", WS_POPUP, 0, 0, 0, 0, 0, 0, instance, 0);
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        data = new NOTIFYICONDATA {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>(), hWnd = hwnd, uID = 1, uFlags = 0x1 | 0x2 | 0x4, // MESSAGE|ICON|TIP
            uCallbackMessage = CallbackMessage, szTip = tip, szInfo = "", szInfoTitle = ""
        };
        LoadIcon();
        Add();
    }

    /// <summary>Windows' taskbar/notification-area theme. Read only; never written.</summary>
    public static bool IsLightTaskbar()
    {
        if (DebugThemeFile is { Length: > 0 } file) {
            try { return File.ReadAllText(file).Trim().Equals("light", StringComparison.OrdinalIgnoreCase); } catch (IOException) { }
        }
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int v && v != 0; // missing value: dark (Windows 11 default)
    }

    void LoadIcon()
    {
        LightTaskbar = IsLightTaskbar();
        // Small-icon size for the current DPI (16 px at 100 %, 24 px at 150 % ...): pick the exact ICO frame.
        int size = GetSystemMetricsForDpi(49 /* SM_CXSMICON */, GetDpiForSystem());
        var icon = LoadImage(0, LightTaskbar ? lightTaskbarIcon : darkTaskbarIcon, 1 /* IMAGE_ICON */, size, size, 0x10 /* LR_LOADFROMFILE */);
        var old = data.hIcon;
        data.hIcon = icon;
        if (old != 0) DestroyIcon(old);
    }

    void Add()
    {
        Shell_NotifyIcon(0 /* NIM_ADD */, ref data);
        data.uVersion = 4; Shell_NotifyIcon(4 /* NIM_SETVERSION */, ref data);
        ThemeApplied?.Invoke(LightTaskbar);
    }

    void Refresh()
    {
        LoadIcon();
        var d = data; d.uFlags = 0x2; // NIF_ICON
        Shell_NotifyIcon(1 /* NIM_MODIFY */, ref d);
        ThemeApplied?.Invoke(LightTaskbar);
    }

    public void SetTip(string tip) { data.szTip = tip.Length > 127 ? tip[..127] : tip; Shell_NotifyIcon(1, ref data); }

    public void ShowBalloon(string title, string text)
    {
        var d = data; d.uFlags = 0x10; d.szInfoTitle = title; d.szInfo = text; d.dwInfoFlags = 1;
        Shell_NotifyIcon(1 /* NIM_MODIFY */, ref d);
    }

    nint Proc(nint h, uint msg, nuint wParam, nint lParam)
    {
        if (msg == taskbarCreated) { LoadIcon(); Add(); return 0; }
        if (msg == WM_SETTINGCHANGE && lParam != 0 && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet") {
            if (IsLightTaskbar() != LightTaskbar) Refresh();
            return 0;
        }
        if (msg == WM_DISPLAYCHANGE || msg == WM_DPICHANGED) { Refresh(); }
        if (msg == CallbackMessage) {
            int ev = LoWord(lParam);
            if (ev == WM_LBUTTONUP || ev == WM_LBUTTONDBLCLK) Activated?.Invoke();
            else if (ev == WM_CONTEXTMENU || ev == WM_RBUTTONUP) ShowMenu();
            return 0;
        }
        return DefWindowProc(h, msg, wParam, lParam);
    }

    void ShowMenu()
    {
        var menu = CreatePopupMenu();
        try {
            foreach (var (id, text, check) in MenuItems?.Invoke() ?? [])
                AppendMenu(menu, text == null ? 0x800u /* SEPARATOR */ : check ? 0x8u /* CHECKED */ : 0u, id, text);
            GetCursorPos(out var pt);
            SetForegroundWindow(hwnd);
            var cmd = TrackPopupMenu(menu, 0x100 /* RETURNCMD */ | 0x80 /* NONOTIFY */ | 0x2 /* RIGHTBUTTON */, pt.X, pt.Y, 0, hwnd, 0);
            PostMessage(hwnd, WM_NULL, 0, 0);
            if (cmd != 0) Command?.Invoke(cmd);
        } finally { DestroyMenu(menu); }
    }

    public void Dispose()
    {
        Shell_NotifyIcon(2 /* NIM_DELETE */, ref data);
        if (data.hIcon != 0) DestroyIcon(data.hIcon);
        DestroyWindow(hwnd);
    }

    [DllImport("user32")] static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32")] static extern uint GetDpiForSystem();
}
