import Darwin
import Foundation

/// Which processes listen on a local TCP port (libproc). Used to prove that 127.0.0.1:port really is our llama-server
/// child before any API key or text is sent. Only processes of the current user can be inspected; a process of
/// another user cannot share 127.0.0.1:port with ours unless both opt in to SO_REUSEPORT, which llama-server does not.
public enum PortOwner {
    /// TCP listeners of `pid` as (address, port) with IPv4 addresses in dotted form ("0.0.0.0" = any).
    public static func listeners(of pid: pid_t) -> [(String, Int)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size) }
        guard got > 0 else { return [] }
        var result: [(String, Int)] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard n == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            var addr = "?"
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                var a = ini.insi_laddr.ina_46.i46a_addr4
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
                addr = String(cString: buf)
            } else if ini.insi_vflag & UInt8(INI_IPV6) != 0 { addr = "ipv6" }
            result.append((addr, port))
        }
        return result
    }

    /// PIDs of the current user's processes listening on 127.0.0.1:port or *:port.
    public static func listeners(port: Int) -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let uid = getuid()
        var owners: [pid_t] = []
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, bsd.pbi_uid == uid else { continue }
            if listeners(of: pid).contains(where: { $0.1 == port && ($0.0 == "127.0.0.1" || $0.0 == "0.0.0.0" || $0.0 == "ipv6") }) { owners.append(pid) }
        }
        return owners
    }

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
