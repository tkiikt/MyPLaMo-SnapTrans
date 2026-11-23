import Foundation

/// Languages supported by PLaMo 3 Translate (PFML3 lang attribute values). Same set as Windows / MyPLaMo.
public struct TranslationLanguage: Identifiable, Hashable, Sendable {
    public let id: String
    public let japanese: String
    public let english: String
    public func name(japaneseUI: Bool) -> String { japaneseUI ? japanese : english }

    public static let all: [TranslationLanguage] = "ja en zh-hans zh-hant ko ar az be bg bn ca ceb de es et eu fa fr gu he hi hr hu hy id it jv ka kk km lt lv ml mr ms my ne nl pa pl ru si sk sl sr sw ta te th tl ur uz vi"
        .split(separator: " ").map(String.init).map { code in
            switch code {
            case "ja": return .init(id: code, japanese: "日本語", english: "Japanese")
            case "en": return .init(id: code, japanese: "英語", english: "English")
            case "zh-hans": return .init(id: code, japanese: "中国語（簡体字）", english: "Chinese (Simplified)")
            case "zh-hant": return .init(id: code, japanese: "中国語（繁体字）", english: "Chinese (Traditional)")
            case "ko": return .init(id: code, japanese: "韓国語", english: "Korean")
            default:
                let native = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
                let english = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
                return .init(id: code, japanese: native, english: english)
            }
        }

    public static func isKnown(_ id: String) -> Bool { all.contains { $0.id == id } }
}

public enum LanguageGuess {
    /// True when the text is mostly Japanese (kana present, or CJK ideographs dominate letters).
    public static func isJapanese(_ text: String) -> Bool {
        var kana = 0, han = 0, latin = 0
        for s in text.unicodeScalars {
            switch s.value {
            case 0x3040...0x30FF, 0xFF66...0xFF9F: kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            default: if CharacterSet.letters.contains(s) { latin += 1 }
            }
        }
        if kana > 0 && kana * 10 >= latin { return true }
        return kana + han > latin
    }

    /// Resolves the "auto" target: Japanese text goes to English, anything else goes to Japanese.
    public static func resolveTarget(_ text: String, setting: String, autoForeign: String = "en") -> String {
        (setting.isEmpty || setting == "auto") ? (isJapanese(text) ? autoForeign : "ja") : setting
    }
}
