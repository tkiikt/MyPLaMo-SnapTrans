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
    public static let userAgent = "MyPLaMo-SnapTrans/1.2.0 (macOS)"

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
        PrivateModelCopy.forget(source: path(of: m))
    }

    /// The file the engine must open for model `m` at `path`: always the owner-only verified copy (PrivateModelCopy),
    /// never the file in the user's folder.
    public static func pinnedModel(_ m: ModelInfo, path: String) throws -> PinnedModel {
        try PrivateModelCopy.prepare(m, path: path)
    }
}

/// The verified, owner-only copy of the selected model that the engine reads, whatever the model folder is (APFS,
/// another volume, exFAT, SMB, a folder others can write…). It lives in `folder` (the app's own
/// ~/Library/Application Support/MyPLaMo-SnapTrans/engine-model, 0700) as model.gguf (0600), with a record of the
/// source file (path + size/mtime/inode stamp) and the SHA-256 of the copy's bytes.
///
/// Making a copy: the source is opened once (no symlinks) and
///   - cloned through that descriptor (APFS, same volume: instant, no extra space), then the clone is always hashed; or
///   - streamed through that descriptor into the copy while hashing the same bytes (one read of the source; needs free
///     space for one more model on the app's volume, checked first: ModelCopyNoSpace otherwise).
/// Only a copy whose bytes hash to an official version is kept. The engine then never reads the user's folder, so a
/// file replaced there after the check is never used. While the source keeps the same stamp the existing copy is
/// reused without re-hashing only while the copy itself is untouched (same device, inode, size, mtime, ctime, owner,
/// 0600, one link, 0700 folder: checkPrivate); one copy is kept at a time and it is removed when the model is deleted in the
/// app, replaced by another model's copy, or its source disappears (removeOrphan at start).
public enum PrivateModelCopy {
    nonisolated(unsafe) public static var folder: URL?
    static let lock = NSLock()
    /// Free space left over after a streamed copy.
    public static let reserve: Int64 = 512 << 20

    struct Record: Codable { let source: String; let sourceStamp: String; let sha256: String; let copyStamp: String }

    static var copyURL: URL? { folder?.appendingPathComponent("model.gguf") }
    static var recordURL: URL? { folder?.appendingPathComponent("model.json") }

    static func loadRecord() -> Record? {
        guard let u = recordURL, let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: d)
    }

    static func removeCopy() {
        if let c = copyURL { unlink(c.path) }
        if let r = recordURL { unlink(r.path) }
    }

    /// The model was deleted in the app: its copy goes too.
    public static func forget(source: String) {
        lock.lock(); defer { lock.unlock() }
        if loadRecord()?.source == source { removeCopy() }
    }

    /// At start: remove a copy whose source no longer exists (deleted outside the app), and unfinished copies.
    public static func removeOrphan() {
        lock.lock(); defer { lock.unlock() }
        guard let f = folder else { return }
        if let r = loadRecord(), !FileManager.default.fileExists(atPath: r.source) { removeCopy() }
        removeIncoming(in: f)
    }

    static func removeIncoming(in f: URL) {
        for n in (try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? [] where n.hasPrefix("incoming-") {
            unlink(f.appendingPathComponent(n).path)
        }
    }

    static func gb(_ n: Int64) -> String { String(format: "%.2f GB", Double(n) / 1e9) }

    /// Identity and protection of a private file: device, inode, size, mtime, ctime (which unprivileged code cannot set
    /// back), owner, mode and link count. Throws unless it is a regular file owned by this user, mode 0600, one link,
    /// in a folder owned by this user with mode 0700.
    static func checkPrivate(_ p: String) throws -> String {
        var st = stat(), dir = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o7777) == 0o600, st.st_nlink == 1
        else { throw SnapTransError("ModelCopyFailed", "permissions") }
        guard lstat((p as NSString).deletingLastPathComponent, &dir) == 0, (dir.st_mode & S_IFMT) == S_IFDIR, dir.st_uid == getuid(),
              (dir.st_mode & 0o7777) == 0o700
        else { throw SnapTransError("ModelCopyFailed", "permissions") }
        return "\(st.st_dev)|\(st.st_ino)|\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)|\(st.st_uid)|\(st.st_mode)|\(st.st_nlink)"
    }

    /// Hashes an open file and, on the same descriptor, enforces mode 0600 (a failing fchmod is an error).
    static func hashPrivate(_ fd: Int32) throws -> String {
        guard fchmod(fd, 0o600) == 0 else { throw SnapTransError("ModelCopyFailed", "chmod") }
        return try FileHash.sha256(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: false))
    }

    public static func prepare(_ m: ModelInfo, path: String) throws -> PinnedModel {
        guard let f = folder else { throw SnapTransError("ModelCopyFailed", "folder") }
        lock.lock(); defer { lock.unlock() }
        try PrivateFiles.ensureDirectory(f)
        var dst = stat()
        guard lstat(f.path, &dst) == 0, (dst.st_mode & S_IFMT) == S_IFDIR, dst.st_uid == getuid() else { throw SnapTransError("ModelCopyFailed", "folder") }
        if (dst.st_mode & 0o7777) != 0o700 { guard chmod(f.path, 0o700) == 0 else { throw SnapTransError("ModelCopyFailed", "chmod") } }
        let copy = copyURL!.path

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapTransError(errno == ELOOP ? "ExistingHashMismatch" : "ModelMissing") }
        let src = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw SnapTransError("ExistingHashMismatch") }
        let size = Int64(st.st_size)
        guard m.isKnownSize(size) else { throw SnapTransError("ExistingHashMismatch") }
        let stamp0 = VerificationCache.stamp(st)

        // Reuse without re-hashing only for our own copy exactly as we left it: same device, inode, size, mtime and
        // ctime, still ours, 0600, one link, in our 0700 folder; and the same source file as when it was made.
        if let r = loadRecord(), r.source == path, r.sourceStamp == stamp0, m.version(for: r.sha256) != nil,
           let now = try? checkPrivate(copy), now == r.copyStamp {
            return PinnedModel(path: copy, stamp: now)
        }

        removeIncoming(in: f)
        let incoming = f.appendingPathComponent("incoming-\(UUID().uuidString).gguf").path
        var sha: String
        if fclonefileat(fd, AT_FDCWD, incoming, 0) == 0 {
            // APFS clone (no extra space). Its content is always hashed: no cache, no trust in the source's attributes.
            let cfd = open(incoming, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard cfd >= 0 else { unlink(incoming); throw SnapTransError("ModelCopyFailed", "clone") }
            defer { close(cfd) }
            do { sha = try hashPrivate(cfd) } catch { unlink(incoming); throw error }
        } else {
            // No clone (another volume, not APFS, SMB…): stream copy + hash in one pass.
            let rv = try? f.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let important = rv?.volumeAvailableCapacityForImportantUsage ?? 0
            let avail = important > 0 ? important : Int64(rv?.volumeAvailableCapacity ?? 0)
            let reuse = (loadRecord() != nil ? (Self.size(copy) ?? 0) : 0)   // the old copy is replaced
            let needed = size + reserve - reuse
            if avail < needed { throw SnapTransError("ModelCopyNoSpace", gb(size), gb(max(0, needed - avail))) }
            let out = open(incoming, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw SnapTransError("ModelCopyFailed", "create") }
            let dstH = FileHandle(fileDescriptor: out, closeOnDealloc: true)
            do {
                guard fchmod(out, 0o600) == 0 else { throw SnapTransError("ModelCopyFailed", "chmod") }
                var hasher = SHA256()
                var done: Int64 = 0
                try src.seek(toOffset: 0)
                while true {
                    try Task.checkCancellation()
                    let chunk = autoreleasepool { src.readData(ofLength: 4 << 20) }
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                    try dstH.write(contentsOf: chunk)
                    done += Int64(chunk.count)
                }
                try dstH.synchronize()
                try dstH.close()
                guard done == size else { throw SnapTransError("ExistingHashMismatch") }
                sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            } catch let e as SnapTransError { unlink(incoming); throw e }
            catch is CancellationError { unlink(incoming); throw CancellationError() }
            catch { unlink(incoming); throw SnapTransError("ModelCopyFailed", "write") }
        }
        guard m.version(for: sha) != nil else { unlink(incoming); throw SnapTransError("ExistingHashMismatch") }
        // The source's own cache entry only when it did not change while it was read.
        if VerificationCache.stamp(fd: fd) == stamp0 { VerificationCache.shared.record(path, stamp: stamp0, sha256: sha) }
        guard rename(incoming, copy) == 0 else { unlink(incoming); throw SnapTransError("ModelCopyFailed", "rename") }
        let copyStamp = try checkPrivate(copy)
        let rec = Record(source: path, sourceStamp: stamp0, sha256: sha, copyStamp: copyStamp)
        if let u = recordURL, let d = try? JSONEncoder().encode(rec) { try PrivateFiles.write(d, to: u) }
        return PinnedModel(path: copy, stamp: copyStamp)
    }

    static func size(_ p: String) -> Int64? { var st = stat(); return stat(p, &st) == 0 ? Int64(st.st_size) : nil }
}

/// The model file an engine start uses: the verified private copy. Only PrivateModelCopy can create one, so the
/// engine cannot be handed any other path (such as the file in the user's folder).
public final class PinnedModel: @unchecked Sendable {
    public let path: String
    let stamp: String
    init(path: String, stamp: String) { self.path = path; self.stamp = stamp }

    /// Right before the engine is spawned: still our regular file, 0600, one link, in our 0700 folder, and unchanged
    /// (device, inode, size, mtime, ctime) since it was verified. Otherwise the engine is not started.
    public func verifyForLaunch() throws {
        guard try PrivateModelCopy.checkPrivate(path) == stamp else { throw SnapTransError("ModelCopyFailed", "changed") }
    }

    /// Called once the engine has loaded the model (nothing to do for the persistent private copy).
    public func afterLoad() throws {}
}
