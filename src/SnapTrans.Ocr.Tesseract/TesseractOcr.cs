using System.Diagnostics;
using System.Runtime.InteropServices;
using SnapTrans.Core;
using TesseractOCR = Tesseract;

namespace SnapTrans.Ocr.Tesseract;

/// <summary>
/// Tesseract 5 (LSTM). Language data (eng/jpn .traineddata from tesseract-ocr/tessdata_fast) lives in
/// <see cref="DataFolder"/> and is downloaded on demand by <see cref="DownloadAsync"/>.
/// </summary>
public sealed class TesseractOcr(string dataFolder) : IOcrEngine
{
    public string Id => "tesseract";
    public string DataFolder { get; } = dataFolder;
    readonly Dictionary<string, TesseractOCR.TesseractEngine> engines = [];

    public static readonly (string Code, string Tag, string Name)[] Known = [("eng", "en", "English"), ("jpn", "ja", "日本語")];

    public IReadOnlyList<OcrLanguage> AvailableLanguages => Known
        .Where(k => File.Exists(Path.Combine(DataFolder, k.Code + ".traineddata")))
        .Select(k => new OcrLanguage(k.Tag, k.Name)).ToArray();

    public Task<OcrResult> RecognizeAsync(OcrImage image, string languageTag, CancellationToken ct) => Task.Run(() => {
        var sw = Stopwatch.StartNew();
        // "" = both installed languages (jpn+eng recognizes mixed text).
        var codes = Known.Where(k => (languageTag == "" || languageTag.StartsWith(k.Tag, StringComparison.OrdinalIgnoreCase))
            && File.Exists(Path.Combine(DataFolder, k.Code + ".traineddata"))).Select(k => k.Code).ToArray();
        if (codes.Length == 0) throw new SnapTransException("OcrLanguageMissing", languageTag);
        var key = string.Join('+', codes.OrderByDescending(c => c == "jpn"));
        foreach (var code in codes) {
            var path = Path.Combine(DataFolder, code + ".traineddata");
            bool known; lock (VerifiedFiles) known = VerifiedFiles.Contains(path);
            if (!known) {
                if (!MatchesAsync(path, code, ct).GetAwaiter().GetResult()) throw new SnapTransException("OcrDataInvalid", code);
                lock (VerifiedFiles) VerifiedFiles.Add(path);
            }
        }
        lock (engines) {
            if (!engines.TryGetValue(key, out var engine))
                engines[key] = engine = new TesseractOCR.TesseractEngine(DataFolder, key, TesseractOCR.EngineMode.LstmOnly);
            using var pix = ToPix(image);
            using var page = engine.Process(pix, TesseractOCR.PageSegMode.Auto);
            var lines = (page.GetText() ?? "").Split('\n').Select(l => l.TrimEnd('\r')).ToArray();
            return new OcrResult(OcrText.Join(lines), lines.Where(l => l.Trim().Length > 0).ToArray(), key, sw.Elapsed);
        }
    }, ct);

    static TesseractOCR.Pix ToPix(OcrImage image)
    {
        // Tesseract prefers dark text on light, ~30px glyphs: grayscale, upscale 2x for small captures.
        int scale = image.Height < 400 ? 2 : 1;
        int w = image.Width * scale, h = image.Height * scale;
        var gray = new byte[image.Width * image.Height]; long sum = 0;
        for (int y = 0; y < image.Height; y++)
            for (int x = 0; x < image.Width; x++) {
                int i = y * image.Stride + x * 4;
                var v = (byte)((image.Bgra[i] * 29 + image.Bgra[i + 1] * 150 + image.Bgra[i + 2] * 77) >> 8);
                gray[y * image.Width + x] = v; sum += v;
            }
        bool invert = sum / Math.Max(1, gray.Length) < 128;
        var pix = TesseractOCR.Pix.Create(w, h, 8);
        var data = pix.GetData();
        for (int y = 0; y < h; y++) {
            var row = data.Data + y * data.WordsPerLine * 4;
            var buffer = new byte[data.WordsPerLine * 4];
            for (int x = 0; x < w; x++) {
                var v = gray[(y / scale) * image.Width + x / scale];
                if (invert) v = (byte)(255 - v);
                // Leptonica stores 8bpp pixels big-endian within 32-bit words.
                buffer[(x & ~3) + (3 - (x & 3))] = v;
            }
            Marshal.Copy(buffer, 0, row, buffer.Length);
        }
        return pix;
    }

    /// <summary>tesseract-ocr/tessdata_fast at tag 4.1.0, pinned to its commit, with the SHA-256 of each file.</summary>
    public const string DataCommit = "65727574dfcd264acbb0c3e07860e4e9e9b22185";
    static readonly Dictionary<string, (string Sha256, long Bytes)> Pinned = new() {
        ["eng"] = ("7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2", 4113088),
        ["jpn"] = ("1f5de9236d2e85f5fdf4b3c500f2d4926f8d9449f28f5394472d9e8d83b91b4d", 2471260),
    };

    /// <summary>
    /// Downloads a language file from the pinned commit into a temporary file, checks size and SHA-256, and only then
    /// moves it into place. A wrong file is deleted and never used.
    /// </summary>
    public static async Task DownloadAsync(string folder, string code, CancellationToken ct)
    {
        var (sha, bytes) = Pinned[code];
        Directory.CreateDirectory(folder);
        var dest = Path.Combine(folder, code + ".traineddata");
        var temp = dest + "." + Guid.NewGuid().ToString("N") + ".download";
        try {
            using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            using (var response = await client.GetAsync($"https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/{DataCommit}/{code}.traineddata", HttpCompletionOption.ResponseHeadersRead, ct)) {
                if (!response.IsSuccessStatusCode) throw new SnapTransException("HttpError", (int)response.StatusCode);
                if (response.Content.Headers.ContentLength is { } length && length != bytes) throw new SnapTransException("SizeMismatch");
                await using var input = await response.Content.ReadAsStreamAsync(ct);
                await using var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                await input.CopyToAsync(output, ct);
            }
            if (!await MatchesAsync(temp, code, ct)) throw new SnapTransException("HashMismatch");
            File.Move(temp, dest, overwrite: true);
            lock (VerifiedFiles) VerifiedFiles.Add(dest);
        } finally {
            if (File.Exists(temp)) File.Delete(temp);
        }
    }

    static async Task<bool> MatchesAsync(string path, string code, CancellationToken ct)
    {
        var (sha, bytes) = Pinned[code];
        var info = new FileInfo(path);
        if (!info.Exists || info.Length != bytes) return false;
        await using var fs = File.OpenRead(path);
        return Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(fs, ct)).Equals(sha, StringComparison.OrdinalIgnoreCase);
    }

    static readonly HashSet<string> VerifiedFiles = new(StringComparer.OrdinalIgnoreCase);

    public void Dispose() { lock (engines) { foreach (var e in engines.Values) e.Dispose(); engines.Clear(); } }
}
