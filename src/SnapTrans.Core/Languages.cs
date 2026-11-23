using System.Globalization;

namespace SnapTrans.Core;

/// <summary>Languages supported by PLaMo 3 Translate (PFML3 lang attribute values).</summary>
public sealed record TranslationLanguage(string Id, string Japanese, string English)
{
    public string Name(bool japaneseUi) => japaneseUi ? Japanese : English;

    public static IReadOnlyList<TranslationLanguage> All { get; } =
        // Same language set MyPLaMo uses with these models.
        "ja en zh-hans zh-hant ko ar az be bg bn ca ceb de es et eu fa fr gu he hi hr hu hy id it jv ka kk km lt lv ml mr ms my ne nl pa pl ru si sk sl sr sw ta te th tl ur uz vi".Split(' ').Select(code => code switch {
            "ja" => new TranslationLanguage(code, "日本語", "Japanese"),
            "en" => new TranslationLanguage(code, "英語", "English"),
            "zh-hans" => new TranslationLanguage(code, "中国語（簡体字）", "Chinese (Simplified)"),
            "zh-hant" => new TranslationLanguage(code, "中国語（繁体字）", "Chinese (Traditional)"),
            "ko" => new TranslationLanguage(code, "韓国語", "Korean"),
            _ => new TranslationLanguage(code, CultureInfo.GetCultureInfo(code).NativeName, CultureInfo.GetCultureInfo(code).EnglishName)
        }).ToArray();

    public static bool IsKnown(string id) => All.Any(l => l.Id == id);
}

public static class LanguageGuess
{
    /// <summary>True when the text is mostly Japanese (kana present, or CJK ideographs dominate letters).</summary>
    public static bool IsJapanese(string text)
    {
        int kana = 0, han = 0, latin = 0;
        foreach (var c in text) {
            if (c is >= '぀' and <= 'ヿ' or >= 'ｦ' and <= 'ﾟ') kana++;
            else if (c is >= '一' and <= '鿿' or >= '㐀' and <= '䶿') han++;
            else if (char.IsLetter(c)) latin++;
        }
        if (kana > 0 && kana * 10 >= latin) return true;
        return kana + han > latin;
    }

    /// <summary>Resolves the "auto" target: Japanese text goes to English, anything else goes to Japanese.</summary>
    public static string ResolveTarget(string text, string targetSetting, string autoForeign = "en")
        => targetSetting is "" or "auto" ? (IsJapanese(text) ? autoForeign : "ja") : targetSetting;
}
