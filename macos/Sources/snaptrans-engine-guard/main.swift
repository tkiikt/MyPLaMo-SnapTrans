// snaptrans-engine-guard <parent-pid> <executable> [args…]
//
// macOS has no job objects: a child of a crashed app is re-parented to launchd and keeps running. SnapTrans starts
// llama-server through this tiny guard, which spawns it, prints "pid <n>" on stdout, and terminates it as soon as the
// app (parent-pid) exits or the guard itself gets SIGTERM/SIGINT/SIGHUP. It exits with the server's status.
import Darwin
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let parent = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: snaptrans-engine-guard <parent-pid> <executable> [args…]\n".data(using: .utf8)!)
    exit(64)
}
// The parent may already be gone (e.g. it was killed between spawn and here).
if getppid() != parent { exit(70) }

for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { signal(s, SIG_IGN) }

var child: pid_t = 0
var cargs: [UnsafeMutablePointer<CChar>?] = args[2...].map { strdup($0) } + [nil]
var attr = posix_spawnattr_t(nil as OpaquePointer?)
posix_spawnattr_init(&attr)
var defaults = sigset_t(); sigemptyset(&defaults)
for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, s) }
posix_spawnattr_setsigdefault(&attr, &defaults)
posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))
let rc = posix_spawn(&child, args[2], nil, &attr, cargs, environ)
if rc != 0 { FileHandle.standardError.write("spawn failed: \(rc)\n".data(using: .utf8)!); exit(71) }
print("pid \(child)"); fflush(stdout)

let kq = kqueue()
var changes = [
    kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil),
    kevent(ident: UInt(child), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil),
    kevent(ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
    kevent(ident: UInt(SIGINT), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
    kevent(ident: UInt(SIGHUP), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
]
// Registering NOTE_EXIT for an already-dead parent fails with ESRCH: treat as "parent gone".
var parentGone = kevent(kq, &changes, Int32(changes.count), nil, 0, nil) < 0 && getppid() != parent

func reap(_ options: Int32) -> Int32? {
    var status: Int32 = 0
    let r = waitpid(child, &status, options)
    if r == child { return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
    return nil
}

func stopChild() -> Never {
    kill(child, SIGTERM)
    for _ in 0..<50 { if let code = reap(WNOHANG) { exit(code) }; usleep(100_000) }
    kill(child, SIGKILL)
    exit(reap(0) ?? 137)
}

if parentGone { stopChild() }
while true {
    var ev = kevent()
    let n = kevent(kq, nil, 0, &ev, 1, nil)
    if n < 0 { if errno == EINTR { continue }; stopChild() }
    if ev.filter == Int16(EVFILT_PROC) && pid_t(ev.ident) == child { exit(reap(0) ?? 1) }
    stopChild()   // parent exited or we were asked to stop
}
