import CryptoKit
import Foundation

/// One file PFN published on Hugging Face for a model (the GGUF changes when the embedded chat template is updated).
public struct ModelVersion: Codable, Hashable, Sendable {
    public let rev: String
    public let date: String
    public let bytes: Int64
    public let sha: String
}

/// Official PLaMo 3 Translate GGUF (Q4_K_M) published by PFN on Hugging Face. Same catalog as the Windows build
/// (src/SnapTrans.Core/catalog.json): downloads are pinned to the current revision, `versions` lists every official
/// file so a genuine older download (e.g. one made by MyPLaMo) is recognised instead of reported as corrupt.
public struct ModelInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let file: String
    public let bytes: Int64
    public let sha: String
    public let url: String
    public let versions: [ModelVersion]

    public static let catalog: [ModelInfo] = {
        let url = Bundle.module.url(forResource: "catalog", withExtension: "json")!
        return try! JSONDecoder().decode([ModelInfo].self, from: Data(contentsOf: url))
    }()

    public static func find(_ id: String) -> ModelInfo? { catalog.first { $0.id == id } }

    public var displayName: String { "plamo-3-translate-\(id)" }
    public var repositoryURL: URL { URL(string: "https://huggingface.co/pfnet/plamo-3-translate-\(id)-GGUF")! }
    public func version(for sha256: String) -> ModelVersion? { versions.first { $0.sha.caseInsensitiveCompare(sha256) == .orderedSame } }
    public func isCurrent(_ sha256: String) -> Bool { sha256.caseInsensitiveCompare(sha) == .orderedSame }
    public func isKnownSize(_ n: Int64) -> Bool { n == bytes || versions.contains { $0.bytes == n } }
}

/// Ready = current official file (size + SHA-256 verified). Outdated = an older official file (usable).
/// Unverified = official size, not hashed yet. Corrupt = size or SHA-256 matches no official file.
public enum ModelState: Sendable { case missing, partial, unverified, corrupt, ready, outdated }

public enum DownloadPhase: Sendable { case connecting, downloading, verifying, done }

public struct DownloadProgress: Sendable {
    public let phase: DownloadPhase
    public let received: Int64
    public let total: Int64
    public let bytesPerSecond: Double
    public var fraction: Double { total <= 0 ? 0 : Double(received) / Double(total) }
}

/// Whether users other than the current one can replace a file (POSIX permissions of the file and its folder).
public enum FolderTrust {
    public static func isWritableByOthers(_ path: String) -> Bool {
        let uid = getuid()
        for p in [path, (path as NSString).deletingLastPathComponent] {
            var st = stat()
            guard stat(p, &st) == 0 else { continue }
            if st.st_uid != uid && st.st_uid != 0 { return true }
            if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return true }
        }
        return false
    }
}

/// SHA-256 results keyed by full path + size + mtime + inode, kept in the app's own folder (never next to the model).
public final class VerificationCache: @unchecked Sendable {
    public static let shared = VerificationCache()
    struct Entry: Codable { let stamp: String; let sha256: String }
    private let lock = NSLock()
    private var entries: [String: Entry]?
    private var session: [String: Entry] = [:]
    /// JSON file for persistence; nil keeps results in memory only.
    public var filePath: URL?

    public static func stamp(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return stamp(st)
    }
    public static func stamp(fd: Int32) -> String? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return stamp(st)
    }
    static func stamp(_ st: stat) -> String { "\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_ino)" }

    private func loaded() -> [String: Entry] {
        if let e = entries { return e }
        var e: [String: Entry] = [:]
        if let f = filePath, let data = try? Data(contentsOf: f), let d = try? JSONDecoder().decode([String: Entry].self, from: data) { e = d }
        entries = e
        return e
    }

    /// The recorded hash if the file is unchanged since it was hashed. For files others can write, only this session's results count.
    public func lookup(_ path: String) -> String? {
        guard let stamp = Self.stamp(path) else { return nil }
        return lookup(path, stamp: stamp)
    }

    /// The recorded hash for `path` if it was recorded for exactly this stamp (e.g. taken from an open descriptor).
    public func lookup(_ path: String, stamp: String) -> String? {
        let persistedOK = !FolderTrust.isWritableByOthers(path)
        lock.lock(); defer { lock.unlock() }
        if let s = session[path], s.stamp == stamp { return s.sha256 }
        if persistedOK, let e = loaded()[path], e.stamp == stamp { return e.sha256 }
        return nil
    }

    public func record(_ path: String, sha256: String) {
        guard let stamp = Self.stamp(path) else { return }
        record(path, stamp: stamp, sha256: sha256)
    }

    public func record(_ path: String, stamp: String, sha256: String) {
        lock.lock(); defer { lock.unlock() }
        var e = loaded()
        e[path] = Entry(stamp: stamp, sha256: sha256.lowercased())
        entries = e
        session[path] = Entry(stamp: stamp, sha256: sha256.lowercased())
        guard let f = filePath else { return }
        try? PrivateFiles.ensureDirectory(f.deletingLastPathComponent(), tighten: false)
        if let data = try? JSONEncoder().encode(e) { try? PrivateFiles.write(data, to: f) }
    }

    public func forget(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _ = loaded()
        entries?[path] = nil
        session[path] = nil
    }
}

public enum FileHash {
    public static func sha256(_ path: String, progress: ((Int64) -> Void)? = nil) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapTransError("ModelMissing") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try sha256(handle: h, progress: progress)
    }

    /// Hashes everything from the start of an already open file (the caller keeps ownership of the descriptor).
    public static func sha256(handle h: FileHandle, progress: ((Int64) -> Void)? = nil) throws -> String {
        try h.seek(toOffset: 0)
        var hasher = SHA256()
        var done: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = autoreleasepool { h.readData(ofLength: 4 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += Int64(chunk.count)
            progress?(done)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Models in a user-chosen folder. Reading (state, SHA-256 verification) never writes to the folder; only the explicit
/// user actions Download and Delete do.
public struct ModelStore: Sendable {
    public let folder: String
    public init(folder: String) { self.folder = folder }
    public static let userAgent = "MyPLaMo-SnapTrans/1.1.0 (macOS)"

    public func path(of m: ModelInfo) -> String { (folder as NSString).appendingPathComponent(m.file) }
    func partPath(of m: ModelInfo) -> String { path(of: m) + ".part" }
    static func size(_ p: String) -> Int64? { (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value }

    public func state(of m: ModelInfo) -> ModelState {
        let p = path(of: m)
        guard let size = Self.size(p) else { return FileManager.default.fileExists(atPath: partPath(of: m)) ? .partial : .missing }
        if !m.isKnownSize(size) { return .corrupt }
        guard let sha = VerificationCache.shared.lookup(p) else { return .unverified }
        if m.isCurrent(sha) { return .ready }
        return m.version(for: sha) != nil ? .outdated : .corrupt
    }

    /// The official version the file was verified as (nil if unverified or not official).
    public func version(of m: ModelInfo) -> ModelVersion? {
        VerificationCache.shared.lookup(path(of: m)).flatMap { m.version(for: $0) }
    }

    public func partialBytes(of m: ModelInfo) -> Int64 { Self.size(partPath(of: m)) ?? 0 }

    /// Downloads the current official file (resumes a .part). With `replaceExisting`, an existing (older) file is
    /// replaced only after the new one has been fully downloaded and verified. The .part is one owner-only (0600) file
    /// handled through a single descriptor from creation to promotion: locked, written, hashed and checked to still be
    /// the same file at its path, then renamed into place while the lock is held.
    public func download(_ m: ModelInfo, replaceExisting: Bool = false,
                         progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        guard folder.hasPrefix("/") else { throw SnapTransError("FolderNotAbsolute") }
        try PrivateFiles.ensureDirectory(URL(fileURLWithPath: folder, isDirectory: true), tighten: false)
        let dest = path(of: m)
        if FileManager.default.fileExists(atPath: dest) && !replaceExisting { _ = try await verify(m, progress: progress); return }
        let part = partPath(of: m)
        let fd = open(part, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SnapTransError("FolderNotWritable") }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // One writer per .part, also across processes (e.g. a second SnapTrans or the CLI); released on close.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SnapTransError("DownloadInProgress") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { throw SnapTransError("FolderNotWritable") }
        if st.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        var offset = Int64(try out.seekToEnd())
        if offset > m.bytes { try out.truncate(atOffset: 0); offset = 0 }
        if let free = (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < m.bytes - offset { throw SnapTransError("DiskFull", m.bytes - offset) }
        if offset < m.bytes {
            progress(.init(phase: .connecting, received: offset, total: m.bytes, bytesPerSecond: 0))
            var req = URLRequest(url: URL(string: m.url)!)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let stream = ChunkStream(request: req)
            let http = try await stream.start()
            guard (200..<300).contains(http.statusCode) else { throw SnapTransError("HttpError", http.statusCode) }
            if http.statusCode == 206 {
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard range.hasPrefix("bytes \(offset)-") else { throw SnapTransError("ResumeMismatch") }
            } else { try out.truncate(atOffset: 0); offset = 0 }
            try out.seek(toOffset: UInt64(offset))
            var position = offset
            let start = Date()
            var lastReport = Date.distantPast
            var buffer = Data(); buffer.reserveCapacity(4 << 20)
            for try await chunk in stream.chunks {
                buffer.append(chunk)
                if buffer.count < 1 << 20 { continue }
                if position + Int64(buffer.count) > m.bytes { throw SnapTransError("SizeMismatch") }
                try out.write(contentsOf: buffer); position += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) >= 0.2 {
                    lastReport = Date()
                    progress(.init(phase: .downloading, received: position, total: m.bytes,
                                   bytesPerSecond: Double(position - offset) / max(0.01, Date().timeIntervalSince(start))))
                }
            }
            if !buffer.isEmpty {
                if position + Int64(buffer.count) > m.bytes { throw SnapTransError("SizeMismatch") }
                try out.write(contentsOf: buffer); position += Int64(buffer.count)
            }
            try out.synchronize()
            try Task.checkCancellation()
            if position != m.bytes { throw SnapTransError("Interrupted") }
        }
        progress(.init(phase: .verifying, received: 0, total: m.bytes, bytesPerSecond: 0))
        // Hash through the same (locked) descriptor that wrote the data.
        let sha = try FileHash.sha256(handle: out) { done in progress(.init(phase: .verifying, received: done, total: m.bytes, bytesPerSecond: 0)) }
        guard m.isCurrent(sha) else { _ = try? out.truncate(atOffset: 0); unlink(part); throw SnapTransError("HashMismatch") }
        // The path must still name the file we hashed before it is promoted.
        var now = stat(), atPath = stat()
        guard fstat(fd, &now) == 0, lstat(part, &atPath) == 0, now.st_dev == atPath.st_dev, now.st_ino == atPath.st_ino else { throw SnapTransError("HashMismatch") }
        let flags: UInt32 = replaceExisting ? 0 : UInt32(RENAME_EXCL)
        guard renamex_np(part, dest, flags) == 0 else { throw SnapTransError(errno == EEXIST ? "DownloadInProgress" : "FolderNotWritable") }
        if let stamp = VerificationCache.stamp(fd: fd) { VerificationCache.shared.record(dest, stamp: stamp, sha256: sha) }
        try out.close()
        progress(.init(phase: .done, received: m.bytes, total: m.bytes, bytesPerSecond: 0))
    }

    /// Verifies an existing file (read-only): size first, then SHA-256 once per file version (cached in the app folder).
    @discardableResult
    public func verify(_ m: ModelInfo, force: Bool = false, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> ModelVersion {
        let p = path(of: m)
        guard let size = Self.size(p) else { throw SnapTransError("ModelMissing") }
        guard m.isKnownSize(size) else { throw SnapTransError("ExistingHashMismatch") }
        var sha = force ? nil : VerificationCache.shared.lookup(p)
        if sha == nil {
            progress?(.init(phase: .verifying, received: 0, total: size, bytesPerSecond: 0))
            let h = try FileHash.sha256(p) { d in progress?(.init(phase: .verifying, received: d, total: size, bytesPerSecond: 0)) }
            VerificationCache.shared.record(p, sha256: h)
            sha = h
            progress?(.init(phase: .done, received: size, total: size, bytesPerSecond: 0))
        }
        guard let v = m.version(for: sha!) else { throw SnapTransError("ExistingHashMismatch") }
        return v
    }

    /// User action (confirmed in the UI): removes the model and a partial download.
    public func delete(_ m: ModelInfo) throws {
        for p in [path(of: m), partPath(of: m)] where FileManager.default.fileExists(atPath: p) {
            try FileManager.default.removeItem(atPath: p)
        }
        VerificationCache.shared.forget(path(of: m))
    }

    /// Runs right before each engine start and returns the file the engine must open: the model is opened once
    /// (no symlinks) and cloned through that descriptor into `privateFolder` (owner-only, 0700), so the engine reads a
    /// copy nobody else can change. The copy is accepted when the opened file is unchanged since a cached official hash
    /// (in a folder only this user can write) or when the copy itself hashes to an official version. Where cloning is
    /// not possible (another volume, not APFS), the verified original is used and must still be the same file, with
    /// the same stamp, once the engine has loaded it.
    public static func pinnedModel(_ m: ModelInfo, path: String, privateFolder: String) throws -> PinnedModel {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapTransError(errno == ELOOP ? "ExistingHashMismatch" : "ModelMissing") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw SnapTransError("ExistingHashMismatch") }
        guard m.isKnownSize(Int64(st.st_size)) else { throw SnapTransError("ExistingHashMismatch") }
        let stamp0 = VerificationCache.stamp(st)
        let trustedFolder = !FolderTrust.isWritableByOthers(path)
        func cachedOK(_ stamp: String) -> Bool {
            trustedFolder && VerificationCache.shared.lookup(path, stamp: stamp).flatMap { m.version(for: $0) } != nil
        }
        let copy = (privateFolder as NSString).appendingPathComponent("model.gguf")
        if fclonefileat(fd, AT_FDCWD, copy, 0) == 0 {
            chmod(copy, 0o600)
            if cachedOK(stamp0), VerificationCache.stamp(fd: fd) == stamp0 { return PinnedModel(path: copy, isCopy: true, handle: nil, original: path, stamp: stamp0) }
            let sha = try FileHash.sha256(copy)
            guard m.version(for: sha) != nil else { unlink(copy); throw SnapTransError("ExistingHashMismatch") }
            if VerificationCache.stamp(fd: fd) == stamp0 { VerificationCache.shared.record(path, stamp: stamp0, sha256: sha) }
            return PinnedModel(path: copy, isCopy: true, handle: nil, original: path, stamp: stamp0)
        }
        if !cachedOK(stamp0) {
            let sha = try FileHash.sha256(handle: h)
            guard m.version(for: sha) != nil, VerificationCache.stamp(fd: fd) == stamp0 else { throw SnapTransError("ExistingHashMismatch") }
            VerificationCache.shared.record(path, stamp: stamp0, sha256: sha)
        }
        return PinnedModel(path: path, isCopy: false, handle: h, original: path, stamp: stamp0)
    }
}

/// The model file an engine start uses (see ModelStore.pinnedModel).
public final class PinnedModel: @unchecked Sendable {
    public let path: String
    let isCopy: Bool
    var handle: FileHandle?
    let original: String
    let stamp: String

    init(path: String, isCopy: Bool, handle: FileHandle?, original: String, stamp: String) {
        self.path = path; self.isCopy = isCopy; self.handle = handle; self.original = original; self.stamp = stamp
    }

    /// Called once the engine has loaded the model: removes the private copy (the engine keeps its open mapping), or
    /// for an uncopied original checks that the path still names the verified, unchanged file.
    public func afterLoad() throws {
        if isCopy { unlink(path); return }
        defer { try? handle?.close(); handle = nil }
        guard let h = handle, VerificationCache.stamp(fd: h.fileDescriptor) == stamp, VerificationCache.stamp(original) == stamp else {
            throw SnapTransError("ExistingHashMismatch")
        }
    }

    deinit {
        if isCopy { unlink(path) }
        try? handle?.close()
    }
}
