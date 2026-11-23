using System.Runtime.InteropServices;
using SnapTrans.Core;
using static SnapTrans.App.Native.Win32;

namespace SnapTrans.App.Native;

static class ScreenCapture
{
    /// <summary>Copies a physical-pixel rectangle of the virtual desktop (may span monitors / negative coordinates).</summary>
    public static OcrImage Capture(RECT r)
    {
        int w = r.Width, h = r.Height;
        var screen = GetDC(0);
        var mem = CreateCompatibleDC(screen);
        var bmi = new BITMAPINFOHEADER { biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
        var dib = CreateDIBSection(screen, ref bmi, 0, out var bits, 0, 0);
        try {
            var old = SelectObject(mem, dib);
            BitBlt(mem, 0, 0, w, h, screen, r.Left, r.Top, 0x00CC0020 /* SRCCOPY */ | 0x40000000 /* CAPTUREBLT */);
            GdiFlush();
            var pixels = new byte[w * h * 4];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            for (int i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
            SelectObject(mem, old);
            return new OcrImage(w, h, w * 4, pixels);
        } finally {
            DeleteObject(dib); DeleteDC(mem); ReleaseDC(0, screen);
        }
    }
}
