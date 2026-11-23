import Foundation
import Testing
@testable import SnapTransCore
@testable import SnapTransEngine

@Suite struct CatalogTests {
    @Test func sameCatalogAsWindows() throws {
        // macOS ships a copy of src/SnapTrans.Core/catalog.json; it must stay identical.
        let here = URL(fileURLWithPath: #filePath)
        let windows = here.deletingLastPathComponent().appendingPathComponent("../../../src/SnapTrans.Core/catalog.json").standardized
        guard FileManager.default.fileExists(atPath: windows.path) else { return }
        let w = try JSONDecoder().decode([ModelInfo].self, from: Data(contentsOf: windows))
        #expect(w == ModelInfo.catalog)
    }

    @Test func catalogShape() {
        #expect(ModelInfo.catalog.map(\.id) == ["0.8b", "2b", "8b", "31b"])
        for m in ModelInfo.catalog {
            #expect(m.url.hasPrefix("https://huggingface.co/pfnet/"))
            #expect(m.isCurrent(m.sha))
            #expect(m.version(for: m.sha.uppercased()) != nil)
            #expect(m.isKnownSize(m.bytes))
            #expect(m.versions.allSatisfy { m.isKnownSize($0.bytes) })
        }
    }
}

@Suite struct PromptTests {
    @Test func pfml3() throws {
        let p = try PlamoPrompt.build(source: "Hello", from: "", to: "ja")
        #expect(p == "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>Hello<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>")
        let q = try PlamoPrompt.build(source: "x", from: "en", to: "ja")
        #expect(q.contains("<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>x"))
    }

    @Test func rejectsControlTokensAndUnknownLanguages() {
        #expect(throws: SnapTransError.self) { try PlamoPrompt.build(source: "a <|plamo:tag|> b", from: "", to: "ja") }
        #expect(throws: SnapTransError.self) { try PlamoPrompt.build(source: "a", from: "", to: "xx") }
    }

    @Test func languages() {
        #expect(Set(TranslationLanguage.all.map(\.id)).count == TranslationLanguage.all.count)
        #expect(TranslationLanguage.isKnown("ja") && TranslationLanguage.isKnown("zh-hant") && !TranslationLanguage.isKnown("xx"))
        #expect(LanguageGuess.resolveTarget("これは日本語です", setting: "auto") == "en")
        #expect(LanguageGuess.resolveTarget("This is English", setting: "auto") == "ja")
        #expect(LanguageGuess.resolveTarget("This is English", setting: "ko") == "ko")
    }
}

@Suite struct OcrTextTests {
    @Test func joinsWrappedLinesAndKeepsBullets() {
        #expect(OcrText.join(["Drag around any text", "on screen."]) == "Drag around any text on screen.")
        #expect(OcrText.join(["auto-", "matic"]) == "automatic")
        #expect(OcrText.join(["日本語の", "文章です。"]) == "日本語の文章です。")
        #expect(OcrText.join(["Title", "", "Body"]) == "Title\nBody")
        #expect(OcrText.join(["Items:", "• one", "• two"]) == "Items:\n• one\n• two")
        #expect(OcrText.cleanLine("日 本 語") == "日本語")
        #expect(OcrText.cleanLine("two   spaces") == "two spaces")
    }
}

@Suite struct EngineTests {
    @Test func manifestNamesTheLinkedFiles() {
        let files = EngineIntegrity.manifest.files
        #expect(files["llama-server"] != nil)
        #expect(files.count == 11)
        #expect(files.values.allSatisfy { $0.count == 64 })
        #expect(EngineIntegrity.manifest.release.contains("b12121"))
    }

    @Test func freePortIsLoopback() throws {
        let p = try LlamaServer.freeLoopbackPort()
        #expect(p > 1024 && p < 65536)
    }

    @Test func tamperedEngineIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snaptrans-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in EngineIntegrity.manifest.files.keys { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        #expect(throws: SnapTransError.self) { try EngineIntegrity.verify(folder: dir.path) }
    }
}

@Suite struct StoreTests {
    @Test func states() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snaptrans-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(folder: dir.path)
        let m = ModelInfo.find("0.8b")!
        #expect(store.state(of: m) == .missing)
        try Data(count: 10).write(to: URL(fileURLWithPath: store.path(of: m) + ".part"))
        #expect(store.state(of: m) == .partial)
        try Data(count: 10).write(to: URL(fileURLWithPath: store.path(of: m)))
        #expect(store.state(of: m) == .corrupt)   // size matches no official file
    }
}
