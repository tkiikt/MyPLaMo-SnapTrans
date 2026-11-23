using System.Runtime.InteropServices;

namespace SnapTrans.App.Native;

public static partial class Win32
{
    public const int WM_DESTROY = 0x0002, WM_PAINT = 0x000F, WM_CLOSE = 0x0010, WM_QUIT = 0x0012, WM_ERASEBKGND = 0x0014,
        WM_DISPLAYCHANGE = 0x007E, WM_DPICHANGED = 0x02E0, WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104,
        WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, WM_LBUTTONDBLCLK = 0x0203,
        WM_RBUTTONUP = 0x0205, WM_CONTEXTMENU = 0x007B, WM_APP = 0x8000, WM_USER = 0x0400, WM_NULL = 0;
    public const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    public const uint WS_POPUP = 0x80000000, WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_TOPMOST = 0x8,
        WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    public const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
    public const uint SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_NOZORDER = 0x4;
    public const uint LWA_COLORKEY = 1;
    public const uint WDA_NONE = 0, WDA_EXCLUDEFROMCAPTURE = 0x11;
    public static readonly nint HWND_TOPMOST = -1, HWND_MESSAGE = -3;
    public const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B, VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    public const uint LLMHF_INJECTED = 1, LLKHF_INJECTED = 0x10;

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int Left, Top, Right, Bottom;
        public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
        public readonly int Width => Right - Left; public readonly int Height => Bottom - Top;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public nint hwnd; public uint message; public nuint wParam; public nint lParam; public uint time; public POINT pt; }
    [StructLayout(LayoutKind.Sequential)] public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public nuint extra; }
    [StructLayout(LayoutKind.Sequential)] public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public nuint extra; }
    [StructLayout(LayoutKind.Sequential)] public struct PAINTSTRUCT { public nint hdc; public int fErase; public RECT rcPaint; public int fRestore, fIncUpdate; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] rgbReserved; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct WNDCLASSEX {
        public uint cbSize, style; public nint lpfnWndProc; public int cbClsExtra, cbWndExtra; public nint hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName; public string lpszClassName; public nint hIconSm;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct MONITORINFOEX { public uint cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
    [StructLayout(LayoutKind.Explicit, Size = 32)] public struct INPUTUNION { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public nuint dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct NOTIFYICONDATA {
        public uint cbSize; public nint hWnd; public uint uID, uFlags, uCallbackMessage; public nint hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags; public Guid guidItem; public nint hBalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth, biHeight; public ushort biPlanes, biBitCount; public uint biCompression, biSizeImage;
        public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant;
    }

    public delegate nint WndProc(nint hwnd, uint msg, nuint wParam, nint lParam);
    public delegate nint HookProc(int code, nuint wParam, nint lParam);
    public delegate bool MonitorEnumProc(nint monitor, nint hdc, ref RECT rect, nint data);

    [DllImport("user32", SetLastError = true, CharSet = CharSet.Unicode)] public static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32", SetLastError = true, CharSet = CharSet.Unicode)] public static extern nint CreateWindowEx(uint exStyle, string className, string? title, uint style, int x, int y, int w, int h, nint parent, nint menu, nint instance, nint param);
    [DllImport("user32")] public static extern bool DestroyWindow(nint hwnd);
    [DllImport("user32")] public static extern nint DefWindowProc(nint hwnd, uint msg, nuint wParam, nint lParam);
    [DllImport("user32")] public static extern int GetMessage(out MSG msg, nint hwnd, uint min, uint max);
    [DllImport("user32")] public static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32")] public static extern nint DispatchMessage(ref MSG msg);
    [DllImport("user32")] public static extern bool PostMessage(nint hwnd, uint msg, nuint wParam, nint lParam);
    [DllImport("user32")] public static extern bool PostThreadMessage(uint thread, uint msg, nuint wParam, nint lParam);
    [DllImport("user32")] public static extern void PostQuitMessage(int code);
    [DllImport("user32", SetLastError = true)] public static extern nint SetWindowsHookEx(int id, HookProc proc, nint module, uint thread);
    [DllImport("user32")] public static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32")] public static extern nint CallNextHookEx(nint hook, int code, nuint wParam, nint lParam);
    [DllImport("user32")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32")] public static extern bool ShowWindow(nint hwnd, int cmd);
    [DllImport("user32")] public static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int w, int h, uint flags);
    [DllImport("user32")] public static extern bool SetLayeredWindowAttributes(nint hwnd, uint key, byte alpha, uint flags);
    [DllImport("user32")] public static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
    [DllImport("user32")] public static extern bool InvalidateRect(nint hwnd, ref RECT rect, bool erase);
    [DllImport("user32")] public static extern bool InvalidateRect(nint hwnd, nint rect, bool erase);
    [DllImport("user32")] public static extern bool UpdateWindow(nint hwnd);
    [DllImport("user32")] public static extern nint BeginPaint(nint hwnd, out PAINTSTRUCT ps);
    [DllImport("user32")] public static extern bool EndPaint(nint hwnd, ref PAINTSTRUCT ps);
    [DllImport("user32")] public static extern int FillRect(nint hdc, ref RECT rect, nint brush);
    [DllImport("user32")] public static extern bool EnumDisplayMonitors(nint hdc, nint clip, MonitorEnumProc proc, nint data);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(nint monitor, ref MONITORINFOEX info);
    [DllImport("user32")] public static extern nint MonitorFromRect(ref RECT rect, uint flags);
    [DllImport("user32")] public static extern nint MonitorFromPoint(POINT pt, uint flags);
    [DllImport("shcore")] public static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32")] public static extern nint GetDC(nint hwnd);
    [DllImport("user32")] public static extern int ReleaseDC(nint hwnd, nint hdc);
    [DllImport("user32")] public static extern bool GetCursorPos(out POINT pt);
    [DllImport("user32")] public static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
    [DllImport("user32")] public static extern nint CreatePopupMenu();
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern bool AppendMenu(nint menu, uint flags, nuint id, string? text);
    [DllImport("user32")] public static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hwnd, nint rect);
    [DllImport("user32")] public static extern bool DestroyMenu(nint menu);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern nint LoadImage(nint instance, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32")] public static extern bool DestroyIcon(nint icon);
    [DllImport("user32")] public static extern nint LoadCursor(nint instance, nint name);
    [DllImport("user32")] public static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("shell32", CharSet = CharSet.Unicode)] public static extern bool Shell_NotifyIcon(uint msg, ref NOTIFYICONDATA data);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] public static extern nint GetModuleHandle(string? name);
    [DllImport("kernel32")] public static extern uint GetCurrentThreadId();
    [DllImport("gdi32")] public static extern nint CreateSolidBrush(uint color);
    [DllImport("gdi32")] public static extern bool DeleteObject(nint obj);
    [DllImport("gdi32")] public static extern nint CreateCompatibleDC(nint hdc);
    [DllImport("gdi32")] public static extern bool DeleteDC(nint hdc);
    [DllImport("gdi32")] public static extern nint SelectObject(nint hdc, nint obj);
    [DllImport("gdi32")] public static extern bool BitBlt(nint dst, int x, int y, int w, int h, nint src, int sx, int sy, uint rop);
    [DllImport("gdi32")] public static extern nint CreateDIBSection(nint hdc, ref BITMAPINFOHEADER bmi, uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32")] public static extern bool GdiFlush();
    [DllImport("dwmapi")] public static extern int DwmFlush();
    [DllImport("dwmapi")] public static extern int DwmSetWindowAttribute(nint hwnd, int attr, ref int value, int size);

    public static uint Rgb(byte r, byte g, byte b) => (uint)(r | (g << 8) | (b << 16));
    public static int LoWord(nint v) => (short)((long)v & 0xFFFF);
    public static int HiWord(nint v) => (short)(((long)v >> 16) & 0xFFFF);

    public static IReadOnlyList<(nint Handle, RECT Bounds, RECT Work)> Monitors()
    {
        var list = new List<(nint, RECT, RECT)>();
        EnumDisplayMonitors(0, 0, (nint m, nint _, ref RECT _, nint _) => {
            var info = new MONITORINFOEX { cbSize = (uint)Marshal.SizeOf<MONITORINFOEX>(), szDevice = "" };
            if (GetMonitorInfo(m, ref info)) list.Add((m, info.rcMonitor, info.rcWork));
            return true;
        }, 0);
        return list;
    }

    public static double ScaleForMonitor(nint monitor) => GetDpiForMonitor(monitor, 0, out var x, out _) == 0 ? x / 96.0 : 1.0;
}
