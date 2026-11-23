import Foundation

/// PFML3 prompts for PLaMo 3 Translate (completion style, no chat template). Same format as the Windows build.
public enum PlamoPrompt {
    public static let stopTokens = ["<|plamo:tag|>", "<|plamo:bos|>"]

    public static func build(source: String, from: String, to: String) throws -> String {
        if source.contains("<|plamo:") { throw SnapTransError("ControlTokens") }
        if !TranslationLanguage.isKnown(to) || (!from.isEmpty && !TranslationLanguage.isKnown(from)) { throw SnapTransError("BadLanguage") }
        func lang(_ v: String) -> String { v.isEmpty ? "" : "<|plamo:key|>lang<|plamo:val|>\(v)" }
        return "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input" + lang(from) + "<|plamo:msg|>" + source
            + "<|plamo:tag|>output" + lang(to) + "<|plamo:msg|>"
    }
}
