import AppKit
import SnapTransCore
import Foundation

/// Modifier keys for drag-to-translate.
struct SnapModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let control = SnapModifiers(rawValue: 1)
    static let option = SnapModifiers(rawValue: 2)
    static let shift = SnapModifiers(rawValue: 4)
    static let command = SnapModifiers(rawValue: 8)

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }

    var text: String {
        var parts: [String] = []
        if contains(.control) { parts.append("Control") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Command") }
        return parts.joined(separator: " + ")
    }
}

/// A global shortcut (virtual key code + modifiers).
struct HotKeySpec: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: SnapModifiers
    var keyLabel: String
    var display: String { modifiers.symbols + keyLabel }
    static let `default` = HotKeySpec(keyCode: 17 /* kVK_ANSI_T */, modifiers: [.control, .shift], keyLabel: "T")
}

/// ~/Library/Application Support/MyPLaMo-SnapTrans/settings.json (test builds: or $SNAPTRANS_PROFILE). Not shared with
/// MyPLaMo. The folder is 0700 and its files 0600.
struct AppSettings: Codable, Equatable {
    static let home: URL = {
        #if SNAPTRANS_TEST_HOOKS
        if let p = ProcessInfo.processInfo.environment["SNAPTRANS_PROFILE"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyPLaMo-SnapTrans", isDirectory: true)
    }()
    static var fileURL: URL { home.appendingPathComponent("settings.json") }
    static var defaultModelFolder: String { home.appendingPathComponent("models").path }

    var modelFolder = AppSettings.defaultModelFolder
    var modelId = ""
    var licenseAccepted = false
    /// "auto" (Metal, CPU fallback) or "cpu".
    var device = "auto"
    /// Control + Shift: Control + Option is VoiceOver's key and the default of other tools (e.g. Genspark Speakly).
    var modifiers: SnapModifiers = [.control, .shift]
    var hotKey: HotKeySpec? = .default
    /// "auto" (Japanese ⇄ English) or a TranslationLanguage id.
    var target = "auto"
    /// "" = automatic, "ja" or "en".
    var ocrLanguage = ""
    /// "auto", "ja-JP" or "en-US".
    var language = "auto"
    /// "system", "light" or "dark".
    var theme = "system"
    var enabled = true

    init() {}

    init(from decoder: Decoder) throws {
        // Tolerant decoding: missing keys keep their defaults.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = AppSettings()
        s.modelFolder = (try? c.decode(String.self, forKey: .modelFolder)) ?? s.modelFolder
        s.modelId = (try? c.decode(String.self, forKey: .modelId)) ?? s.modelId
        s.licenseAccepted = (try? c.decode(Bool.self, forKey: .licenseAccepted)) ?? s.licenseAccepted
        s.device = (try? c.decode(String.self, forKey: .device)) ?? s.device
        s.modifiers = (try? c.decode(SnapModifiers.self, forKey: .modifiers)) ?? s.modifiers
        if c.contains(.hotKey) { s.hotKey = try? c.decode(HotKeySpec?.self, forKey: .hotKey) }
        s.target = (try? c.decode(String.self, forKey: .target)) ?? s.target
        s.ocrLanguage = (try? c.decode(String.self, forKey: .ocrLanguage)) ?? s.ocrLanguage
        s.language = (try? c.decode(String.self, forKey: .language)) ?? s.language
        s.theme = (try? c.decode(String.self, forKey: .theme)) ?? s.theme
        s.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? s.enabled
        self = s
    }

    /// Creates the app folder as 0700 and tightens files an earlier version created with the default umask.
    static func preparePrivateHome() {
        try? PrivateFiles.ensureDirectory(home)
        for n in ["settings.json", "verify-cache.json", "snaptrans.log", "snaptrans.log.1"] { PrivateFiles.tighten(home.appendingPathComponent(n)) }
        let models = home.appendingPathComponent("models")
        if FileManager.default.fileExists(atPath: models.path) { try? PrivateFiles.ensureDirectory(models) }
    }

    static func load() -> AppSettings {
        preparePrivateHome()
        guard let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        try? PrivateFiles.ensureDirectory(Self.home)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? PrivateFiles.write(data, to: Self.fileURL) }
    }
}

/// Diagnostic log (~/Library/Application Support/MyPLaMo-SnapTrans/snaptrans.log, 0600). Callers pass fixed text and
/// numbers only: never recognized or translated text, file paths or keys. Enforced by an allowlist of characters (no
/// "/", "~", non-ASCII text…): a line outside it is reduced to its first word. Rotated at 1 MB.
enum AppLog {
    static let queue = DispatchQueue(label: "snaptrans.log")
    static func allowed(_ line: String) -> String {
        if line.count <= 400, line.range(of: #"^[A-Za-z0-9 ._:;=+()%,?-]*$"#, options: .regularExpression) != nil { return line }
        let head = line.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == ":" || $0 == "-") }.prefix(60)
        return "\(head) [redacted]"
    }
    static func log(_ raw: String) {
        let line = allowed(raw)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        queue.async {
            let url = AppSettings.home.appendingPathComponent("snaptrans.log")
            try? PrivateFiles.ensureDirectory(AppSettings.home)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 1_000_000 {
                let old = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            PrivateFiles.append(Data("\(stamp) \(line)\n".utf8), to: url)
        }
    }
    static func error(_ context: String, _ e: Error) {
        if let s = e as? SnapTransErrorLike { log("\(context): \(s.safeDescription)") }
        else { log("\(context): \(type(of: e)) \((e as NSError).code)") }
    }
}
