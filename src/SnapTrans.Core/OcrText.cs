using System.Text;
using System.Text.RegularExpressions;

namespace SnapTrans.Core;

/// <summary>Turns OCR lines into translatable paragraphs.</summary>
public static partial class OcrText
{
    static bool IsCjk(char c) => c is >= '　' and <= 'ヿ' or >= '㐀' and <= '䶿' or >= '一' and <= '鿿' or >= '＀' and <= '￯' or >= '가' and <= '힯';

    /// <summary>Removes the spaces some recognizers insert between CJK characters.</summary>
    public static string CleanLine(string line)
    {
        var sb = new StringBuilder(line.Length);
        for (int i = 0; i < line.Length; i++) {
            var c = line[i];
            if (c == ' ' && sb.Length > 0) {
                int j = i; while (j < line.Length && line[j] == ' ') j++;
                if (j < line.Length && (IsCjk(sb[^1]) || IsCjk(line[j]))) { i = j - 1; continue; }
                if (j < line.Length && sb[^1] != ' ') sb.Append(' ');
                i = j - 1; continue;
            }
            sb.Append(c);
        }
        return sb.ToString().Trim();
    }

    /// <summary>
    /// Joins visual lines into paragraphs. Lines are merged unless the previous line ends a sentence
    /// and the next one looks like a new block (bullet/heading), so wrapped sentences translate as one.
    /// </summary>
    public static string Join(IEnumerable<string> lines)
    {
        var sb = new StringBuilder();
        string prev = "";
        foreach (var raw in lines) {
            var line = CleanLine(raw);
            if (line.Length == 0) { if (sb.Length > 0 && !sb.ToString().EndsWith('\n')) sb.Append('\n'); prev = ""; continue; }
            if (sb.Length == 0 || prev == "") { sb.Append(line); prev = line; continue; }
            bool newBlock = BulletRegex().IsMatch(line);
            if (newBlock) sb.Append('\n').Append(line);
            else if (prev.EndsWith('-') && prev.Length > 1 && char.IsLetter(prev[^2]) && char.IsLower(line[0])) { sb.Length--; sb.Append(line); }
            else if (IsCjk(prev[^1]) && IsCjk(line[0])) sb.Append(line);
            else sb.Append(' ').Append(line);
            prev = line;
        }
        return sb.ToString().Trim();
    }

    [GeneratedRegex(@"^(?:[•・●◦▪■□\-–—*]\s|\d{1,3}[.)]\s|[A-Za-z][.)]\s)")]
    private static partial Regex BulletRegex();
}
