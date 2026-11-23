using System.Runtime.InteropServices;
using static SnapTrans.App.Native.Win32;

namespace SnapTrans.App.Native;

[Flags]
public enum SnapModifiers { None = 0, Ctrl = 1, Alt = 2, Shift = 4, Win = 8 }

/// <summary>
/// Global "modifier + left drag" selection.
/// <list type="bullet">
/// <item>Hook thread: owns WH_MOUSE_LL / WH_KEYBOARD_LL and does nothing but pump messages. The callbacks only
/// decide, record two points and post a message, so Windows never times them out.</item>
/// <item>Overlay thread: a hidden control window and one click-through, top-most overlay per monitor
/// (physical pixels, Per-Monitor V2). It draws the frame and reacts to display changes.</item>
/// <item>Capture (DwmFlush + BitBlt + pixel copy) runs on the thread pool after the frame is hidden.</item>
/// </list>
/// </summary>
sealed class SnapInput : IDisposable
{
    const uint MsgBegin = WM_APP + 1, MsgMove = WM_APP + 2, MsgEnd = WM_APP + 3, MsgCancel = WM_APP + 4, MsgQuit = WM_APP + 5;
    public const int MinSize = 6;

    public event Action? Began;
    /// <summary>Raised (overlay thread) for Esc, a selection smaller than <see cref="MinSize"/>, or a display change mid-drag.</summary>
    public event Action<string>? Canceled;
    /// <summary>Raised on a thread-pool thread with the selection and its pixels (captured after the frame is hidden).</summary>
    public event Action<RECT, Core.OcrImage?>? Completed;

    public volatile SnapModifiers Modifiers = SnapModifiers.Ctrl | SnapModifiers.Alt;
    public volatile bool Enabled = true;
    /// <summary>Non-null when a hook could not be installed (Win32 error text).</summary>
    public string? HookError { get; private set; }
    /// <summary>
    /// Called on the capture thread before the screen is read; completes once the app's own windows that could cover
    /// the selection (the result popup) are hidden.
    /// </summary>
    public Func<Task>? BeforeCapture;
    /// <summary>Documentation switch: let screenshots show the selection frame (it is excluded from capture by default).</summary>
    public static bool VisibleToCapture => Environment.GetEnvironmentVariable("SNAPTRANS_SHOW_IN_CAPTURE") == "1";
    /// <summary>Test switch: pretend SetWindowsHookEx failed for "mouse", "keyboard" or "both".</summary>
    static string? DebugFailHook => Environment.GetEnvironmentVariable("SNAPTRANS_DEBUG_FAIL_HOOK");

    readonly Thread hookThread, overlayThread;
    readonly ManualResetEventSlim hookReady = new(), overlayReady = new();
    uint hookThreadId;
    nint control, mouseHook, keyboardHook;
    HookProc? mouseProc, keyboardProc;
    WndProc? controlProc, overlayProc;
    readonly List<Overlay> overlays = [];   // overlay thread only
    RECT drawn;                              // overlay thread only
    nint keyBrush, darkBrush, lightBrush;

    // Shared between the hook thread (writer) and the overlay thread (reader).
    readonly object sync = new();
    POINT start, current;
    volatile bool dragging;
    volatile int session, abortedSession;
    bool swallowUp;                          // hook thread only
    int movePending;

    sealed class Overlay { public nint Hwnd; public RECT Bounds; }

    /// <summary>
    /// One hook owner per user session, whatever the profile: a second SnapTrans (e.g. another SNAPTRANS_PROFILE) would
    /// otherwise also swallow the same clicks and translate every selection twice.
    /// </summary>
    readonly Mutex? hookOwner;
    public bool AnotherInstanceOwnsHooks { get; }

    public SnapInput()
    {
        hookOwner = new Mutex(true, @"Local\MyPLaMo.SnapTrans.InputHooks", out var owner);
        if (!owner) { hookOwner.Dispose(); hookOwner = null; AnotherInstanceOwnsHooks = true; }
        overlayThread = new Thread(RunOverlay) { IsBackground = true, Name = "SnapOverlay" };
        overlayThread.SetApartmentState(ApartmentState.STA);
        overlayThread.Start();
        overlayReady.Wait();
        hookThread = new Thread(RunHooks) { IsBackground = true, Name = "SnapHook" };
        hookThread.Start();
        hookReady.Wait();
    }

    // ---------------- Hook thread ----------------
    void RunHooks()
    {
        hookThreadId = GetCurrentThreadId();
        var instance = GetModuleHandle(null);
        mouseProc = MouseHook; keyboardProc = KeyboardHook;
        var errors = new List<string>();
        if (AnotherInstanceOwnsHooks) {
            HookError = "another SnapTrans instance owns the input hooks";
            hookReady.Set();
            while (GetMessage(out var idle, 0, 0, 0) > 0) { TranslateMessage(ref idle); DispatchMessage(ref idle); }
            return;
        }
        var fail = DebugFailHook;
        mouseHook = fail is "mouse" or "both" ? 0 : SetWindowsHookEx(WH_MOUSE_LL, mouseProc, instance, 0);
        if (mouseHook == 0) errors.Add($"WH_MOUSE_LL: {(fail is "mouse" or "both" ? "simulated failure" : new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message)}");
        keyboardHook = fail is "keyboard" or "both" ? 0 : SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, instance, 0);
        if (keyboardHook == 0) errors.Add($"WH_KEYBOARD_LL: {(fail is "keyboard" or "both" ? "simulated failure" : new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message)}");
        HookError = errors.Count == 0 ? null : string.Join("; ", errors);
        hookReady.Set();
        // Message pump only: low-level hook callbacks are delivered through it.
        while (GetMessage(out var msg, 0, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
        if (mouseHook != 0) UnhookWindowsHookEx(mouseHook);
        if (keyboardHook != 0) UnhookWindowsHookEx(keyboardHook);
    }

    static bool Down(int vk) => GetAsyncKeyState(vk) < 0;

    static SnapModifiers HeldModifiers()
    {
        var m = SnapModifiers.None;
        if (Down(VK_CONTROL)) m |= SnapModifiers.Ctrl;
        if (Down(VK_MENU)) m |= SnapModifiers.Alt;
        if (Down(VK_SHIFT)) m |= SnapModifiers.Shift;
        if (Down(VK_LWIN) || Down(VK_RWIN)) m |= SnapModifiers.Win;
        return m;
    }

    nint MouseHook(int code, nuint wParam, nint lParam)
    {
        if (code >= 0) {
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            switch ((int)wParam) {
                case WM_LBUTTONDOWN when !dragging && Enabled && Modifiers != SnapModifiers.None && HeldModifiers() == Modifiers:
                    lock (sync) { start = current = info.pt; }
                    session++;
                    dragging = swallowUp = true;
                    PostMessage(control, MsgBegin, (nuint)session, 0);
                    return 1; // the app under the cursor never sees this click
                case WM_MOUSEMOVE when dragging:
                    lock (sync) current = info.pt;
                    if (Interlocked.Exchange(ref movePending, 1) == 0) PostMessage(control, MsgMove, 0, 0);
                    break;
                case WM_LBUTTONUP when swallowUp:
                    swallowUp = false;
                    if (dragging) {
                        dragging = false;
                        lock (sync) current = info.pt;
                        if (abortedSession != session) PostMessage(control, MsgEnd, (nuint)session, 0);
                    }
                    return 1;
            }
        }
        return CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    nint KeyboardHook(int code, nuint wParam, nint lParam)
    {
        if (code >= 0 && dragging && ((int)wParam == WM_KEYDOWN || (int)wParam == WM_SYSKEYDOWN)) {
            var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            if (info.vkCode == VK_ESCAPE) { dragging = false; PostMessage(control, MsgCancel, (nuint)session, 0); return 1; }
        }
        return CallNextHookEx(keyboardHook, code, wParam, lParam);
    }

    RECT Selection()
    {
        lock (sync) return new(Math.Min(start.X, current.X), Math.Min(start.Y, current.Y), Math.Max(start.X, current.X) + 1, Math.Max(start.Y, current.Y) + 1);
    }

    // ---------------- Overlay thread ----------------
    void RunOverlay()
    {
        var instance = GetModuleHandle(null);
        controlProc = ControlProc; overlayProc = OverlayProc;
        var cls = new WNDCLASSEX { cbSize = (uint)Marshal.SizeOf<WNDCLASSEX>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(controlProc), hInstance = instance, lpszClassName = "SnapTrans.Control" };
        RegisterClassEx(ref cls);
        var ocls = new WNDCLASSEX { cbSize = (uint)Marshal.SizeOf<WNDCLASSEX>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(overlayProc), hInstance = instance, lpszClassName = "SnapTrans.Overlay", hCursor = LoadCursor(0, 32515 /* IDC_CROSS */) };
        RegisterClassEx(ref ocls);
        // A hidden top-level (not message-only) window so WM_DISPLAYCHANGE is delivered.
        control = CreateWindowEx(WS_EX_TOOLWINDOW, "SnapTrans.Control", "SnapTrans.Control", WS_POPUP, 0, 0, 0, 0, 0, 0, instance, 0);
        keyBrush = CreateSolidBrush(Rgb(255, 0, 255));
        darkBrush = CreateSolidBrush(Rgb(20, 28, 40));
        lightBrush = CreateSolidBrush(Rgb(96, 205, 255));
        CreateOverlays();
        overlayReady.Set();
        while (GetMessage(out var msg, 0, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
        DestroyOverlays();
        DestroyWindow(control);
        DeleteObject(keyBrush); DeleteObject(darkBrush); DeleteObject(lightBrush);
    }

    void CreateOverlays()
    {
        foreach (var (_, bounds, _) in Monitors()) {
            var hwnd = CreateWindowEx(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                "SnapTrans.Overlay", "SnapTrans selection", WS_POPUP, bounds.Left, bounds.Top, bounds.Width, bounds.Height, 0, 0, GetModuleHandle(null), 0);
            SetLayeredWindowAttributes(hwnd, Rgb(255, 0, 255), 255, LWA_COLORKEY);
            if (!VisibleToCapture) SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
            overlays.Add(new Overlay { Hwnd = hwnd, Bounds = bounds });
        }
    }

    void DestroyOverlays() { foreach (var o in overlays) DestroyWindow(o.Hwnd); overlays.Clear(); }

    nint ControlProc(nint hwnd, uint msg, nuint wParam, nint lParam)
    {
        switch (msg) {
            case MsgBegin:
                if ((int)wParam != session || abortedSession == session) return 0;
                // Alt / Win released "alone" would open the menu bar / Start. A neutral key press prevents that.
                if ((Modifiers & (SnapModifiers.Alt | SnapModifiers.Win)) != 0) SendNeutralKey();
                drawn = default;
                foreach (var o in overlays) SetWindowPos(o.Hwnd, HWND_TOPMOST, o.Bounds.Left, o.Bounds.Top, o.Bounds.Width, o.Bounds.Height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
                Began?.Invoke();
                Redraw();
                return 0;
            case MsgMove:
                Interlocked.Exchange(ref movePending, 0);
                if (dragging) Redraw();
                return 0;
            case MsgEnd: {
                var rect = Selection();
                HideOverlays();
                if (rect.Width < MinSize || rect.Height < MinSize) { Canceled?.Invoke("small"); return 0; }
                // Capture off this thread; DwmFlush there makes sure the hidden frame is gone from the screen.
                ThreadPool.QueueUserWorkItem(_ => {
                    Core.OcrImage? image = null;
                    try {
                        // The popup is visible to screen capture (so users can take screenshots of it): make sure it is
                        // hidden and that DWM has composed a frame without it before reading the pixels.
                        try { BeforeCapture?.Invoke().Wait(TimeSpan.FromSeconds(2)); } catch (Exception ex) { AppHost.LogError("before capture", ex); }
                        DwmFlush(); DwmFlush();
                        image = ScreenCapture.Capture(rect);
                    } catch (Exception ex) { AppHost.LogError("capture", ex); }
                    Completed?.Invoke(rect, image);
                });
                return 0;
            }
            case MsgCancel:
                HideOverlays(); Canceled?.Invoke("esc");
                return 0;
            case WM_DISPLAYCHANGE: {
                // Monitors were added/removed/resized: rebuild the overlays. A drag in progress is abandoned
                // because its coordinates may no longer map to the same screen content.
                bool wasDragging = dragging;
                if (wasDragging) { abortedSession = session; dragging = false; }
                DestroyOverlays(); CreateOverlays(); drawn = default;
                if (wasDragging) Canceled?.Invoke("display");
                return 0;
            }
            case MsgQuit:
                PostQuitMessage(0);
                return 0;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    void HideOverlays()
    {
        foreach (var o in overlays) ShowWindow(o.Hwnd, SW_HIDE);
        drawn = default;
    }

    void Redraw()
    {
        var sel = Selection();
        foreach (var o in overlays) {
            // Invalidate the old and new frame areas (local coordinates) only.
            foreach (var r in new[] { drawn, sel }) {
                if (r.Width <= 0) continue;
                var local = new RECT(r.Left - o.Bounds.Left - 4, r.Top - o.Bounds.Top - 4, r.Right - o.Bounds.Left + 4, r.Bottom - o.Bounds.Top + 4);
                InvalidateRect(o.Hwnd, ref local, false);
            }
            UpdateWindow(o.Hwnd);
        }
        drawn = sel;
    }

    nint OverlayProc(nint hwnd, uint msg, nuint wParam, nint lParam)
    {
        switch (msg) {
            case WM_ERASEBKGND: return 1;
            case WM_DPICHANGED: return 0; // keep our physical-pixel bounds
            case WM_PAINT: {
                var hdc = BeginPaint(hwnd, out var ps);
                var o = overlays.FirstOrDefault(x => x.Hwnd == hwnd);
                FillRect(hdc, ref ps.rcPaint, keyBrush);
                if (o != null && dragging) {
                    var s = Selection();
                    var r = new RECT(s.Left - o.Bounds.Left, s.Top - o.Bounds.Top, s.Right - o.Bounds.Left, s.Bottom - o.Bounds.Top);
                    Frame(hdc, new RECT(r.Left - 2, r.Top - 2, r.Right + 2, r.Bottom + 2), 1, darkBrush);
                    Frame(hdc, new RECT(r.Left - 1, r.Top - 1, r.Right + 1, r.Bottom + 1), 2, lightBrush);
                    Frame(hdc, new RECT(r.Left + 1, r.Top + 1, r.Right - 1, r.Bottom - 1), 1, darkBrush);
                }
                EndPaint(hwnd, ref ps);
                return 0;
            }
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    static void Frame(nint hdc, RECT r, int t, nint brush)
    {
        var top = new RECT(r.Left, r.Top, r.Right, r.Top + t); FillRect(hdc, ref top, brush);
        var bottom = new RECT(r.Left, r.Bottom - t, r.Right, r.Bottom); FillRect(hdc, ref bottom, brush);
        var left = new RECT(r.Left, r.Top, r.Left + t, r.Bottom); FillRect(hdc, ref left, brush);
        var right = new RECT(r.Right - t, r.Top, r.Right, r.Bottom); FillRect(hdc, ref right, brush);
    }

    static void SendNeutralKey()
    {
        // 0xE8 is unassigned; the same trick PowerToys uses to keep Alt/Win from triggering menus.
        INPUT Key(bool up) => new() { type = 1, u = new INPUTUNION { ki = new KEYBDINPUT { wVk = 0xE8, dwFlags = up ? 2u : 0u } } };
        SendInput(2, [Key(false), Key(true)], Marshal.SizeOf<INPUT>());
    }

    public void Dispose()
    {
        try { hookOwner?.ReleaseMutex(); } catch (ApplicationException) { }
        hookOwner?.Dispose();
        if (hookThreadId != 0) PostThreadMessage(hookThreadId, WM_QUIT, 0, 0);
        if (control != 0) PostMessage(control, MsgQuit, 0, 0);
        hookThread.Join(2000);
        overlayThread.Join(2000);
    }
}
