// Developer tool: download / verify models, OCR an image and translate with the bundled engine, timing each step.
//   snaptrans-cli download <id> <folder>
//   snaptrans-cli verify <id> <folder>
//   snaptrans-cli ocr <image> [auto|ja|en]
//   snaptrans-cli translate <id> <folder> <metal|cpu|auto> <text|@file> [runs]
//   snaptrans-cli snap <id> <folder> <metal|cpu|auto> <image>
//   snaptrans-cli debug <command…>   (to an app started with SNAPTRANS_DEBUG_COMMANDS=1, see DebugCommands.swift)
import Foundation
import SnapTransCore
import SnapTransEngine
import SnapTransOCR

setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func model(_ id: String) -> ModelInfo { guard let m = ModelInfo.find(id) else { fail("unknown model \(id)") }; return m }
VerificationCache.shared.filePath = FileManager.default.temporaryDirectory.appendingPathComponent("snaptrans-cli-verify.json")

func translator(_ id: String, _ folder: String, _ sel: String) -> PlamoTranslator {
    let t = PlamoTranslator(locator: .bundled())
    let m = model(id)
    let path = ModelStore(folder: folder).path(of: m)
    t.configure(modelPath: path, selection: sel) { dir in try ModelStore.pinnedModel(m, path: path, privateFolder: dir) }
    t.diagnostic = { print("[engine] \($0)") }
    return t
}

do {
    switch a.count > 1 ? a[1] : "" {
    case "download":
        let m = model(a[2])
        var last = Date.distantPast
        try await ModelStore(folder: a[3]).download(m) { p in
            if Date().timeIntervalSince(last) > 2 || p.phase == .done { last = Date(); print(String(format: "%@ %.1f%% %.1f MB/s", "\(p.phase)", p.fraction * 100, p.bytesPerSecond / 1e6)) }
        }
        print("state:", ModelStore(folder: a[3]).state(of: m))
    case "verify":
        let v = try await ModelStore(folder: a[3]).verify(model(a[2]), force: true)
        print("verified rev \(v.rev) \(v.date)")
    case "ocr":
        let r = try await VisionOCR.recognize(file: URL(fileURLWithPath: a[2]), language: a.count > 3 ? a[3] : "")
        print(String(format: "ocr %.0f ms", r.elapsed * 1000)); print(r.text)
    case "translate":
        let t = translator(a[2], a[3], a[4])
        var text = a[5]
        if text.hasPrefix("@") { text = try String(contentsOfFile: String(text.dropFirst()), encoding: .utf8) }
        let t0 = Date()
        let l = try await t.ensureLoaded()
        print(String(format: "load %.2f s backend=%@ fallback=%@", Date().timeIntervalSince(t0), l.backend.rawValue, l.fallbackReason ?? "-"))
        for i in 0..<(a.count > 6 ? Int(a[6])! : 1) {
            let to = LanguageGuess.resolveTarget(text, setting: "auto")
            let r = try await t.translate(text, to: to)
            print(String(format: "run %d: %.2f s", i + 1, r.elapsed)); if i == 0 { print(r.text) }
        }
        await t.shutdown()
    case "snap":
        let t = translator(a[2], a[3], a[4])
        let o = try await VisionOCR.recognize(file: URL(fileURLWithPath: a[5]), language: "")
        print(String(format: "ocr %.0f ms\n%@", o.elapsed * 1000, o.text))
        let r = try await t.translate(o.text, to: LanguageGuess.resolveTarget(o.text, setting: "auto"))
        print(String(format: "translate %.2f s\n%@", r.elapsed, r.text))
        await t.shutdown()
    case "debug":
        DistributedNotificationCenter.default().postNotificationName(.init("io.github.tkiikt.MyPLaMo-SnapTrans.debug" + (ProcessInfo.processInfo.environment["SNAPTRANS_DEBUG_TARGET"].map { "." + $0 } ?? "")),
            object: a.dropFirst(2).joined(separator: " "), userInfo: nil, deliverImmediately: true)
    default: fail("see the header of Sources/snaptrans-cli/main.swift")
    }
} catch { fail("error: \(error)") }
