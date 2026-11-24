import Darwin
import Foundation

/// Files and folders the app creates for itself are owner-only: folders 0700, files 0600 (independent of the umask).
public enum PrivateFiles {
    /// Creates `url` (and missing parents) as 0700. An existing folder owned by the current user is tightened to 0700
    /// only when `tighten` is true (the app's own folder, never a folder the user picked).
    public static func ensureDirectory(_ url: URL, tighten: Bool = true) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if !isDir.boolValue {
            throw CocoaError(.fileWriteFileExists)
        }
        if tighten {
            var st = stat()
            if lstat(url.path, &st) == 0, st.st_uid == getuid(), (st.st_mode & 0o777) != 0o700 { chmod(url.path, 0o700) }
        }
    }

    /// Writes `data` atomically: a 0600 temporary file in the same folder, then rename over `url`.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        var template = Array(dir.appendingPathComponent(".\(url.lastPathComponent).XXXXXX").path.utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }   // mkstemp creates 0600
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let tmp = String(cString: template)
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            fchmod(fd, 0o600)
            try h.write(contentsOf: data)
            try h.close()
            guard rename(tmp, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(tmp)
            throw error
        }
    }

    /// Appends `data` to `url`, creating it as 0600. Never follows a symbolic link.
    public static func append(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) == 0, (st.st_mode & 0o077) != 0 { fchmod(fd, 0o600) }
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// Restricts an existing file the app owns to 0600.
    public static func tighten(_ url: URL) {
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o077) != 0 { chmod(url.path, 0o600) }
    }
}
