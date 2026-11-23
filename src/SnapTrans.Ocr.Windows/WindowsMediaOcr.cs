using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using SnapTrans.Core;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using OcrResult = SnapTrans.Core.OcrResult;

namespace SnapTrans.Ocr.Windows;

/// <summary>
/// Windows.Media.Ocr. Uses whatever OCR language packs Windows already has; never installs or changes anything.
/// "" (auto) picks the first available of: Japanese (handles Latin too), then the user's profile languages.
/// </summary>
public sealed class WindowsMediaOcr : IOcrEngine
{
    public string Id => "windows";

    public IReadOnlyList<OcrLanguage> AvailableLanguages =>
        OcrEngine.AvailableRecognizerLanguages.Select(l => new OcrLanguage(l.LanguageTag, l.NativeName)).ToArray();

    public static bool HasLanguage(string prefix) =>
        OcrEngine.AvailableRecognizerLanguages.Any(l => l.LanguageTag.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));

    public async Task<OcrResult> RecognizeAsync(OcrImage image, string languageTag, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var engine = CreateEngine(languageTag) ?? throw new SnapTransException("OcrLanguageMissing", languageTag);
        // Small UI text recognizes much better when enlarged; Windows OCR wants ~20px+ glyphs.
        int scale = image.Height < 200 ? 3 : image.Height < 600 ? 2 : 1;
        var max = (int)OcrEngine.MaxImageDimension;
        while (scale > 1 && (image.Width * scale > max || image.Height * scale > max)) scale--;
        using var bitmap = ToBitmap(image, scale);
        ct.ThrowIfCancellationRequested();
        var result = await engine.RecognizeAsync(bitmap).AsTask(ct);
        var lines = Lines(result);
        var tag = engine.RecognizerLanguage.LanguageTag;
        // Auto: the Japanese recognizer reads Latin text poorly ("To Do" -> "DO"). When the capture is not purely
        // Japanese, read it again with a Latin recognizer and keep, line by line, the Japanese lines from the first pass.
        if (string.IsNullOrEmpty(languageTag) && tag.StartsWith("ja", StringComparison.OrdinalIgnoreCase)
            && lines.Any(l => !LanguageGuess.IsJapanese(l.Text))) {
            var latin = OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(l => !l.LanguageTag.StartsWith("ja", StringComparison.OrdinalIgnoreCase)
                && !l.LanguageTag.StartsWith("zh", StringComparison.OrdinalIgnoreCase) && !l.LanguageTag.StartsWith("ko", StringComparison.OrdinalIgnoreCase));
            if (latin != null && OcrEngine.TryCreateFromLanguage(latin) is { } second) {
                var japanese = lines.Where(l => LanguageGuess.IsJapanese(l.Text)).ToList();
                var other = Lines(await second.RecognizeAsync(bitmap).AsTask(ct))
                    .Where(l => !japanese.Any(j => Overlap(j, l) > 0.5 * Math.Min(j.Bottom - j.Top, l.Bottom - l.Top))).ToList();
                lines = japanese.Concat(other).OrderBy(l => l.Top).ThenBy(l => l.Left).ToList();
                tag = japanese.Count > 0 ? $"{tag}+{latin.LanguageTag}" : latin.LanguageTag;
            }
        }
        return new(OcrText.Join(WithParagraphBreaks(lines)), lines.Select(l => l.Text).ToArray(), tag, sw.Elapsed);
    }

    sealed record Line(string Text, double Left, double Top, double Bottom);

    static List<Line> Lines(global::Windows.Media.Ocr.OcrResult result) => result.Lines.Where(l => l.Words.Count > 0).Select(l => new Line(l.Text,
        l.Words.Min(w => w.BoundingRect.X), l.Words.Min(w => w.BoundingRect.Y), l.Words.Max(w => w.BoundingRect.Y + w.BoundingRect.Height))).ToList();

    static double Overlap(Line a, Line b) => Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);

    /// <summary>A vertical gap clearly larger than the usual line spacing starts a new paragraph.</summary>
    static IEnumerable<string> WithParagraphBreaks(List<Line> lines)
    {
        if (lines.Count == 0) yield break;
        var gaps = lines.Zip(lines.Skip(1), (a, b) => b.Top - a.Bottom).Where(g => g > 0).OrderBy(g => g).ToList();
        double typical = gaps.Count > 0 ? gaps[gaps.Count / 4] : 0 /* lower quartile: most gaps are plain line gaps */;
        double height = lines.Select(l => l.Bottom - l.Top).OrderBy(h => h).ElementAt(lines.Count / 2);
        for (int i = 0; i < lines.Count; i++) {
            if (i > 0) {
                double gap = lines[i].Top - lines[i - 1].Bottom;
                double heightRatio = (lines[i - 1].Bottom - lines[i - 1].Top) / Math.Max(1, lines[i].Bottom - lines[i].Top);
                if (gap > Math.Max(typical * 1.35, height * 0.45) || heightRatio > 1.3 || heightRatio < 0.77) yield return "";
            }
            yield return lines[i].Text;
        }
    }

    static OcrEngine? CreateEngine(string tag)
    {
        if (!string.IsNullOrEmpty(tag)) {
            var lang = OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(l => l.LanguageTag.Equals(tag, StringComparison.OrdinalIgnoreCase))
                ?? OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(l => l.LanguageTag.StartsWith(tag.Split('-')[0], StringComparison.OrdinalIgnoreCase));
            return lang == null ? null : OcrEngine.TryCreateFromLanguage(lang);
        }
        var ja = OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(l => l.LanguageTag.StartsWith("ja", StringComparison.OrdinalIgnoreCase));
        return ja != null ? OcrEngine.TryCreateFromLanguage(ja) : OcrEngine.TryCreateFromUserProfileLanguages();
    }

    static SoftwareBitmap ToBitmap(OcrImage image, int scale)
    {
        int w = image.Width * scale, h = image.Height * scale;
        var pixels = new byte[w * h * 4];
        if (scale == 1) {
            for (int y = 0; y < h; y++) Buffer.BlockCopy(image.Bgra, y * image.Stride, pixels, y * w * 4, w * 4);
        } else {
            // Bilinear upscale keeps glyph edges smoother than nearest-neighbour for the recognizer.
            for (int y = 0; y < h; y++) {
                double sy = Math.Max(0, (y + 0.5) / scale - 0.5); int y0 = (int)sy, y1 = Math.Min(y0 + 1, image.Height - 1); double fy = sy - y0;
                for (int x = 0; x < w; x++) {
                    double sx = Math.Max(0, (x + 0.5) / scale - 0.5); int x0 = (int)sx, x1 = Math.Min(x0 + 1, image.Width - 1); double fx = sx - x0;
                    int d = (y * w + x) * 4;
                    for (int c = 0; c < 4; c++) {
                        double a = image.Bgra[y0 * image.Stride + x0 * 4 + c], b = image.Bgra[y0 * image.Stride + x1 * 4 + c];
                        double e = image.Bgra[y1 * image.Stride + x0 * 4 + c], f = image.Bgra[y1 * image.Stride + x1 * 4 + c];
                        pixels[d + c] = (byte)Math.Round((a * (1 - fx) + b * fx) * (1 - fy) + (e * (1 - fx) + f * fx) * fy);
                    }
                }
            }
        }
        return SoftwareBitmap.CreateCopyFromBuffer(pixels.AsBuffer(), BitmapPixelFormat.Bgra8, w, h, BitmapAlphaMode.Premultiplied);
    }

    public void Dispose() { }
}
