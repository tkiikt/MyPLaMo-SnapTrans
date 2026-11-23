import Foundation

/// Turns OCR lines into translatable paragraphs (port of the Windows OcrText).
public enum OcrText {
    static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(s) || (0x3400...0x4DBF).contains(s) || (0x4E00...0x9FFF).contains(s)
            || (0xFF00...0xFFEF).contains(s) || (0xAC00...0xD7AF).contains(s)
    }

    /// Removes the spaces some recognizers insert between CJK characters and collapses runs of spaces.
    public static func cleanLine(_ line: String) -> String {
        let chars = Array(line)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " && !out.isEmpty {
                var j = i
                while j < chars.count && chars[j] == " " { j += 1 }
                if j < chars.count && (isCJK(out.last!) || isCJK(chars[j])) { i = j; continue }
                if j < chars.count && out.last! != " " { out.append(" ") }
                i = j; continue
            }
            out.append(c); i += 1
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    static let bullet = try! NSRegularExpression(pattern: #"^(?:[•・●◦▪■□\-–—*]\s|\d{1,3}[.)]\s|[A-Za-z][.)]\s)"#)

    /// Joins visual lines into paragraphs: wrapped sentences become one, bullets start a new line.
    public static func join(_ lines: [String]) -> String {
        var sb = ""
        var prev = ""
        for raw in lines {
            let line = cleanLine(raw)
            if line.isEmpty { if !sb.isEmpty && !sb.hasSuffix("\n") { sb += "\n" }; prev = ""; continue }
            if sb.isEmpty || prev.isEmpty { sb += line; prev = line; continue }
            let newBlock = bullet.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            if newBlock { sb += "\n" + line }
            else if prev.hasSuffix("-") && prev.count > 1 && prev.dropLast().last!.isLetter && line.first!.isLowercase { sb.removeLast(); sb += line }
            else if isCJK(prev.last!) && isCJK(line.first!) { sb += line }
            else { sb += " " + line }
            prev = line
        }
        return sb.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
