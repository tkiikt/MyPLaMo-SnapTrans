using System.Diagnostics;

namespace SnapTrans.Core;

public enum SnapStage { Recognizing, LoadingModel, Translating, Done }

public sealed record SnapOutcome(OcrResult Ocr, TranslationResult? Translation);

/// <summary>OCR → translate. UI-independent so the macOS app can reuse the same flow.</summary>
public sealed class SnapPipeline(IOcrEngine ocr, ITranslator translator)
{
    public async Task<SnapOutcome> RunAsync(OcrImage image, string ocrLanguage, string targetSetting, IProgress<SnapStage>? stage, CancellationToken ct)
    {
        stage?.Report(SnapStage.Recognizing);
        var recognized = await ocr.RecognizeAsync(image, ocrLanguage, ct);
        if (string.IsNullOrWhiteSpace(recognized.Text)) return new(recognized, null);
        stage?.Report(SnapStage.Translating);
        var to = LanguageGuess.ResolveTarget(recognized.Text, targetSetting);
        var translated = await translator.TranslateAsync(new(recognized.Text, "", to), ct);
        stage?.Report(SnapStage.Done);
        return new(recognized, translated);
    }
}

public static class Timing
{
    public static async Task<(T Value, TimeSpan Elapsed)> Measure<T>(Func<Task<T>> action)
    {
        var sw = Stopwatch.StartNew();
        var value = await action();
        return (value, sw.Elapsed);
    }
}
