import Darwin
import Foundation

/// A process identified by PID *and* start time, so a recycled PID is never mistaken for it (libproc).
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let startSec: UInt64
    public let startUsec: UInt64

    /// The identity of `pid` as it runs now (nil if it does not exist or belongs to another user).
    public static func of(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
              bsd.pbi_uid == getuid() else { return nil }
        return ProcessIdentity(pid: pid, startSec: bsd.pbi_start_tvsec, startUsec: bsd.pbi_start_tvusec)
    }

    /// True while the very same process (not a later one with a recycled PID) is alive.
    public var isAlive: Bool { Self.of(pid) == self }
}

/// libproc helpers used to prove that the process llama-server's socket belongs to is our own child.
public enum PortOwner {
    public static func parent(of pid: pid_t) -> pid_t? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return pid_t(bsd.pbi_ppid)
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}
