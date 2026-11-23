using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using SnapTrans.Core;
using SnapTrans.Llama;
using SnapTrans.Ocr.Tesseract;
using SnapTrans.Ocr.Windows;
using Windows.Graphics.Imaging;
using Windows.Storage;

Console.OutputEncoding = System.Text.Encoding.UTF8;
var engineRoot = Environment.GetEnvironmentVariable("SNAPTRANS_ENGINE") ?? Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "engine");
var locator = new EngineLocator(Path.GetFullPath(engineRoot), Path.Combine(Environment.GetEnvironmentVariable("SNAPTRANS_PROFILE") ?? "", "engine"));
switch (args.FirstOrDefault()) {
    case "download": {
        var store = new ModelStore(args[2]);
        var m = ModelInfo.Find(args[1])!;
        long last = 0;
        await store.DownloadAsync(m, new Progress<DownloadProgress>(p => { if (Environment.TickCount64 - last > 5000 || p.Phase != DownloadPhase.Downloading) { last = Environment.TickCount64; Console.WriteLine($"{p.Phase} {p.Fraction:P1} {p.BytesPerSecond / 1e6:0.0} MB/s"); } }), CancellationToken.None);
        Console.WriteLine($"OK {store.PathOf(m)}");
        break;
    }
    case "state": {
        var store = new ModelStore(args[1]);
        foreach (var m in ModelInfo.Catalog) Console.WriteLine($"{m.Id}	{store.StateOf(m)}");
        break;
    }
    case "installcuda": {
        // installcuda <root> <vcRuntimeSource>   (uses <root>\downloads if the official zips are already there)
        await CudaEngineInstaller.InstallAsync(args[1], null, args[2], null, CancellationToken.None);
        Console.WriteLine("installed; files: " + string.Join(" ", Directory.GetFiles(Path.Combine(args[1], "cuda")).Select(Path.GetFileName).Where(n => n!.StartsWith("msvc") || n.StartsWith("vcrun"))));
        await EngineIntegrity.EnsureVerifiedAsync(Path.Combine(args[1], "cuda"), "cuda", CancellationToken.None);
        Console.WriteLine("cuda folder verified");
        break;
    }
    case "devices": {
        var cat = await locator.DiscoverAsync(CancellationToken.None);
        foreach (var d in cat.Devices) Console.WriteLine($"{d.Key}\t{d.Label}\t{d.MemoryMiB} MiB\tintegrated={d.Integrated}");
        foreach (var e in cat.Errors) Console.WriteLine("ERR " + e);
        Console.WriteLine("best: " + cat.BestGpu?.Label);
        break;
    }
    case "ocr": {
        // ocr <image> [tessdata]  — same image through each engine/language, 1 warm-up + 3 timed runs
        var image = await Load(args[1]);
        var engines = new List<(string, IOcrEngine, string)>();
        var win = new WindowsMediaOcr();
        Console.WriteLine("Windows OCR languages: " + string.Join(", ", win.AvailableLanguages.Select(l => l.Tag)));
        foreach (var tag in new[] { "en-US", "ja", "" }) engines.Add(($"windows[{(tag == "" ? "auto" : tag)}]", win, tag));
        if (args.Length > 2) { var t = new TesseractOcr(args[2]); foreach (var tag in new[] { "en", "ja", "" }) engines.Add(($"tesseract[{(tag == "" ? "jpn+eng" : tag)}]", t, tag)); }
        foreach (var (name, engine, tag) in engines) {
            await engine.RecognizeAsync(image, tag, default);
            var times = new List<double>(); OcrResult? r = null;
            for (int i = 0; i < 3; i++) { var sw = Stopwatch.StartNew(); r = await engine.RecognizeAsync(image, tag, default); times.Add(sw.Elapsed.TotalMilliseconds); }
            times.Sort();
            Console.WriteLine($"=== {name}  median {times[1]:0} ms");
            Console.WriteLine(r!.Text);
        }
        break;
    }
    case "translate": {
        // translate <modelFolder> <id> <device> <text> [to]
        var store = new ModelStore(args[1]); var m = ModelInfo.Find(args[2])!;
        var tr = new PlamoTranslator(locator);
        tr.Diagnostic += m => Console.WriteLine("[diag] " + m);
        tr.Configure(store.PathOf(m), args[3]);
        var sw = Stopwatch.StartNew();
        var loaded = await tr.EnsureLoadedAsync(default);
        Console.WriteLine($"loaded on {loaded.Device.Label} in {sw.Elapsed.TotalSeconds:0.00}s fallback={loaded.FallbackReason}");
        var to = args.Length > 5 ? args[5] : LanguageGuess.ResolveTarget(args[4], "auto");
        var times = new List<double>(); TranslationResult? res = null;
        for (int i = 0; i < 4; i++) { res = await tr.TranslateAsync(new(args[4], "", to), default); if (i > 0) times.Add(res.Elapsed.TotalSeconds); }
        times.Sort();
        Console.WriteLine($"median {times[1]:0.000}s  [{string.Join(", ", times.Select(t => t.ToString("0.000")))}]");
        Console.WriteLine(res!.Text);
        await tr.ShutdownAsync(TimeSpan.FromSeconds(5));
        break;
    }
    default:
        Console.WriteLine("download <id> <folder> | devices | ocr <png> [tessdata] | translate <folder> <id> <auto|cpu|key> <text> [to]");
        break;
}

static async Task<OcrImage> Load(string path)
{
    var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
    using var stream = await file.OpenReadAsync();
    var decoder = await BitmapDecoder.CreateAsync(stream);
    using var bmp = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
    var bytes = new byte[bmp.PixelWidth * bmp.PixelHeight * 4];
    bmp.CopyToBuffer(bytes.AsBuffer());
    return new OcrImage(bmp.PixelWidth, bmp.PixelHeight, bmp.PixelWidth * 4, bytes);
}
