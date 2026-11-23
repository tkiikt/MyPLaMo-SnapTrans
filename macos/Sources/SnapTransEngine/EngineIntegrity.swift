import Foundation
import SnapTransCore

/// Verifies the bundled engine folder (llama-server and its dylibs) against the SHA-256 manifest of the pinned
/// llama.cpp release before anything in it is started. The folder must contain exactly the manifest's Mach-O files
/// (no extra dylib that the loader could pick up; no symlinks). Verified once per session per folder.
public enum EngineIntegrity {
    public struct Manifest: Decodable { public let release: String; public let files: [String: String] }
    public static let manifest: Manifest = {
        let url = Bundle.module.url(forResource: "engine-manifest", withExtension: "json")!
        return try! JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var verified: Set<String> = []

    static func isCode(_ name: String) -> Bool { name.hasSuffix(".dylib") || name.hasSuffix(".so") || name == "llama-server" || !name.contains(".") && !name.hasPrefix("LICENSE") }

    public static func verify(folder: String) throws {
        lock.lock(); let done = verified.contains(folder); lock.unlock()
        if done { return }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        for n in names where isCode(n) && manifest.files[n] == nil { throw SnapTransError("EngineTampered", "metal", "unexpected file") }
        for (name, sha) in manifest.files {
            let p = (folder as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: p)
            guard let type = attrs?[.type] as? FileAttributeType else { throw SnapTransError("EngineTampered", "metal", "missing file") }
            if type != .typeRegular { throw SnapTransError("EngineTampered", "metal", "not a regular file") }
            if try FileHash.sha256(p) != sha { throw SnapTransError("EngineTampered", "metal", "hash mismatch") }
        }
        lock.lock(); verified.insert(folder); lock.unlock()
    }
}
