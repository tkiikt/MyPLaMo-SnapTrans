import CoreGraphics
import Foundation
import SnapTransCore
import Vision

public struct OcrResult: Sendable {
    public let text: String
    public let lines: [String]
    public let languages: [String]
    public let elapsed: TimeInterval
}

/// Vision text recognition (RecognizeTextRequest, accurate). `language`: "" = automatic (Vision detects the
/// language among Japanese and English), "ja" or "en" = fixed.
public enum VisionOCR {
    public static func recognize(_ image: CGImage, language: String) async throws -> OcrResult {
        let t0 = Date()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        switch language {
        case "ja": request.recognitionLanguages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        case "en": request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        default:
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        }
        let observations = try await request.perform(on: image)
        // Reading order: top to bottom (Vision's origin is bottom-left), then left to right.
        let sorted = observations.sorted { a, b in
            let ya = a.boundingBox.origin.y + a.boundingBox.height, yb = b.boundingBox.origin.y + b.boundingBox.height
            if abs(ya - yb) > min(a.boundingBox.height, b.boundingBox.height) * 0.5 { return ya > yb }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        }
        var lines: [String] = []
        var lastBottom: CGFloat?
        var lastHeight: CGFloat = 0
        for o in sorted {
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { continue }
            let top = o.boundingBox.origin.y + o.boundingBox.height
            // A vertical gap larger than one line height separates paragraphs.
            if let lb = lastBottom, lb - top > max(lastHeight, o.boundingBox.height) * 1.0 { lines.append("") }
            lines.append(s)
            lastBottom = o.boundingBox.origin.y; lastHeight = o.boundingBox.height
        }
        let text = OcrText.join(lines)
        return OcrResult(text: text, lines: lines, languages: request.recognitionLanguages.map { $0.maximalIdentifier }, elapsed: Date().timeIntervalSince(t0))
    }

    /// Runs one tiny recognition so the system loads Vision's text models before the first real selection
    /// (the first request after a restart can otherwise take tens of seconds).
    public static func prewarm() async {
        let w = 64, h = 24
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return }
        _ = try? await recognize(img, language: "")
    }

    public static func recognize(file: URL, language: String) async throws -> OcrResult {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SnapTransError("ImageUnreadable")
        }
        return try await recognize(img, language: language)
    }
}
