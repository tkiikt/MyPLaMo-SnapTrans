using System.Text;

namespace SnapTrans.Core;

/// <summary>Builds PFML3 prompts for PLaMo 3 Translate (completion style, no chat template).</summary>
public static class PlamoPrompt
{
    public static readonly string[] StopTokens = ["<|plamo:tag|>", "<|plamo:bos|>"];

    public static string Build(string source, string from, string to)
    {
        if (source.Contains("<|plamo:", StringComparison.Ordinal)) throw new SnapTransException("ControlTokens");
        if (!TranslationLanguage.IsKnown(to) || (from != "" && !TranslationLanguage.IsKnown(from))) throw new SnapTransException("BadLanguage");
        static string Lang(string value) => value == "" ? "" : $"<|plamo:key|>lang<|plamo:val|>{value}";
        return new StringBuilder("<|plamo:tag|>dataset<|plamo:msg|>translation")
            .Append("<|plamo:tag|>input").Append(Lang(from)).Append("<|plamo:msg|>").Append(source)
            .Append("<|plamo:tag|>output").Append(Lang(to)).Append("<|plamo:msg|>")
            .ToString();
    }
}
