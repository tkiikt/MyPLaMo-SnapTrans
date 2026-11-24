import Darwin
import Foundation
import SnapTransCore

/// Verifies the bundled engine folder (llama-server and its dylibs) and the guard against the SHA-256 manifest before
/// anything in it is started, on every engine start (not cached). The folder must contain exactly the manifest's
/// Mach-O files (no extra dylib that the loader could pick up; no symlinks), and neither it nor the files may be
/// writable by other users.
///
/// The manifest in the source tree (Resources/engine-manifest.json) lists the pinned llama.cpp release's own files
/// (checked by prepare-engine.sh when they are fetched). build-app.sh re-signs the engine for distribution and then
/// writes the manifest of the final, signed bytes (plus the guard's hash under "guard") into the app bundle before the
/// app itself is sealed, so the app always checks exactly the bytes it ships.
public enum EngineIntegrity {
    public struct Manifest: Decodable {
        public let release: String
        public let files: [String: String]
        public let guardSHA256: String?
        enum CodingKeys: String, CodingKey { case release, files, guardSHA256 = "guard" }
    }
    public static let manifest: Manifest = {
        let url = Bundle.module.url(forResource: "engine-manifest", withExtension: "json")!
        return try! JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }()

    static func isCode(_ name: String) -> Bool { name.hasSuffix(".dylib") || name.hasSuffix(".so") || name == "llama-server" || !name.contains(".") && !name.hasPrefix("LICENSE") }

    /// SHA-256 of a regular file opened without following symlinks; throws EngineTampered otherwise.
    static func hashRegular(_ p: String, _ what: String) throws -> String {
        let fd = open(p, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapTransError("EngineTampered", "metal", errno == ELOOP ? "not a regular file" : "missing file") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw SnapTransError("EngineTampered", "metal", "not a regular file") }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 || (st.st_uid != getuid() && st.st_uid != 0) { throw SnapTransError("EngineTampered", "metal", "writable by others") }
        return try FileHash.sha256(handle: h)
    }

    public static func verify(folder: String, guardPath: String? = nil, manifest m: Manifest = manifest) throws {
        if FolderTrust.isWritableByOthers((folder as NSString).appendingPathComponent(".")) { throw SnapTransError("EngineTampered", "metal", "writable by others") }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for n in names where isCode(n) && m.files[n] == nil { throw SnapTransError("EngineTampered", "metal", "unexpected file") }
        for (name, sha) in m.files {
            if try hashRegular((folder as NSString).appendingPathComponent(name), name) != sha { throw SnapTransError("EngineTampered", "metal", "hash mismatch") }
        }
        if let guardPath {
            if let gsha = m.guardSHA256 {
                if try hashRegular(guardPath, "guard") != gsha { throw SnapTransError("EngineTampered", "guard", "hash mismatch") }
            } else {
                #if !SNAPTRANS_TEST_HOOKS
                // A distribution build always ships a manifest with the guard's hash (written by build-app.sh).
                throw SnapTransError("EngineTampered", "guard", "missing hash")
                #endif
            }
        }
    }
}
