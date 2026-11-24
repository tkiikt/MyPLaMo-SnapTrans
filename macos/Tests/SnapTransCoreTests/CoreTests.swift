import CryptoKit
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

    @Test func randomKeyAndRunFolder() throws {
        let k = try LlamaServer.randomKey()
        #expect(k.count == 32)
        let dir = try LlamaServer.makeRunFolder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mode = (try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as! NSNumber).intValue
        #expect(mode == 0o700)
    }

    @Test func httpParsing() throws {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Type: application/json\r\n\r\n{\"a\"}".utf8)
        let r = try UnixHTTP.parse(plain, complete: false)
        #expect(r.status == 200 && String(decoding: r.body, as: UTF8.self) == "{\"a\"")
        let chunked = Data("HTTP/1.1 503 Busy\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)
        let c = try UnixHTTP.parse(chunked, complete: false)
        #expect(c.status == 503 && String(decoding: c.body, as: UTF8.self) == "abcde")
        #expect(throws: UnixHTTP.Incomplete.self) { try UnixHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nab".utf8), complete: false) }
    }

    @Test func tamperedEngineIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snaptrans-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in EngineIntegrity.manifest.files.keys { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        #expect(throws: SnapTransError.self) { try EngineIntegrity.verify(folder: dir.path) }
    }
}

@Suite(.serialized) struct StoreTests {
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
        // A file of the wrong size is never handed to the engine.
        #expect(throws: SnapTransError.self) { PrivateModelCopy.folder = dir.appendingPathComponent("copy"); try ModelStore.pinnedModel(m, path: store.path(of: m)) }
    }

    @Test func privateCopyIsRequiredAndChecked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snaptrans-copy-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data(repeating: 7, count: 4096)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let json = #"{"id":"t","file":"t.gguf","bytes":4096,"sha":"\#(sha)","url":"https://example.invalid/t","versions":[{"rev":"r","date":"d","bytes":4096,"sha":"\#(sha)"}]}"#
        let m = try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        let src = root.appendingPathComponent("t.gguf")
        try data.write(to: src)
        PrivateModelCopy.folder = root.appendingPathComponent("copy")
        let pin = try ModelStore.pinnedModel(m, path: src.path)
        #expect(pin.path != src.path)
        try pin.verifyForLaunch()
        let attrs = { (p: String) in (try FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as! NSNumber).intValue }
        #expect(try attrs(pin.path) == 0o600)
        // Mode broken → not launched; the next prepare makes a fresh verified copy.
        chmod(pin.path, 0o644)
        #expect(throws: SnapTransError.self) { try pin.verifyForLaunch() }
        let pin2 = try ModelStore.pinnedModel(m, path: src.path)
        try pin2.verifyForLaunch()
        // Folder mode broken → not launched.
        chmod(PrivateModelCopy.folder!.path, 0o755)
        #expect(throws: SnapTransError.self) { try pin2.verifyForLaunch() }
        chmod(PrivateModelCopy.folder!.path, 0o700)
        // A second link (someone else's name for the same inode) → not launched.
        link(pin2.path, root.appendingPathComponent("other").path)
        #expect(throws: SnapTransError.self) { try pin2.verifyForLaunch() }
        unlink(root.appendingPathComponent("other").path)
        // Content changed (same size) → not launched; a fresh copy is made from the source.
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: pin2.path)); try h.write(contentsOf: Data([1])); try h.close()
        #expect(throws: SnapTransError.self) { try pin2.verifyForLaunch() }
        let pin3 = try ModelStore.pinnedModel(m, path: src.path)
        try pin3.verifyForLaunch()
        #expect(try Data(contentsOf: URL(fileURLWithPath: pin3.path)) == data)
        // Tampered source → rejected.
        try Data(repeating: 8, count: 4096).write(to: src)
        #expect(throws: SnapTransError.self) { try ModelStore.pinnedModel(m, path: src.path) }
    }

    @Test func privateFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snaptrans-private-test-\(UUID().uuidString)/sub")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try PrivateFiles.ensureDirectory(dir)
        let f = dir.appendingPathComponent("a.json")
        try PrivateFiles.write(Data("{}".utf8), to: f)
        PrivateFiles.append(Data("x".utf8), to: dir.appendingPathComponent("log"))
        func mode(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        #expect(try mode(dir) == 0o700)
        #expect(try mode(f) == 0o600)
        #expect(try mode(dir.appendingPathComponent("log")) == 0o600)
        #expect(try String(contentsOf: f, encoding: .utf8) == "{}")
    }
}
