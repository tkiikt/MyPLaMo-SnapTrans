namespace SnapTrans.Core;

/// <summary>A captured screen region in 32-bit BGRA (premultiplied/opaque) pixel format.</summary>
public sealed record OcrImage(int Width, int Height, int Stride, byte[] Bgra);

public sealed record OcrLanguage(string Tag, string DisplayName);

public sealed record OcrResult(string Text, IReadOnlyList<string> Lines, string LanguageTag, TimeSpan Elapsed);

/// <summary>Text recognition. Implementations: Windows.Media.Ocr (Windows), Tesseract, Vision (future macOS).</summary>
public interface IOcrEngine : IDisposable
{
    string Id { get; }
    /// <summary>Recognizer languages that are installed and usable right now.</summary>
    IReadOnlyList<OcrLanguage> AvailableLanguages { get; }
    /// <param name="languageTag">BCP-47 tag from <see cref="AvailableLanguages"/>, or "" to let the engine decide.</param>
    Task<OcrResult> RecognizeAsync(OcrImage image, string languageTag, CancellationToken ct);
}

public sealed record TranslationRequest(string Text, string From, string To);

public sealed record TranslationResult(string Text, string From, string To, TimeSpan Elapsed);

/// <summary>Machine translation. Implementation: PLaMo 3 Translate on llama-server.</summary>
public interface ITranslator
{
    Task<TranslationResult> TranslateAsync(TranslationRequest request, CancellationToken ct);
}

/// <summary>An error whose user-facing text is chosen by the UI (Code = resource key suffix).</summary>
public sealed class SnapTransException(string code, params object[] args) : Exception(code)
{
    public string Code { get; } = code;
    public object[] Args { get; } = args;
}
