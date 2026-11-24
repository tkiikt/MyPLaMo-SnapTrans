import Darwin
import Foundation
import SnapTransCore

/// Minimal HTTP/1.1 client over a Unix domain socket (one request per connection, "Connection: close").
/// llama-server listens on a socket inside an owner-only (0700) folder, so no other user can reach it, and every
/// connection is checked with LOCAL_PEERPID / getpeereid before anything (API key, text) is written to it: the check
/// is tied to the very connection that carries the request.
enum UnixHTTP {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }

    static let maxResponse = 32 << 20

    /// Connects to `socketPath`; throws `ConnectFailed` when nobody listens (yet).
    struct ConnectFailed: Error { let errno: Int32 }

    /// One file descriptor shared with the cancellation handler (shutdown unblocks a blocking read/write).
    final class Conn: @unchecked Sendable {
        let lock = NSLock()
        var fd: Int32 = -1
        var cancelled = false
        func cancel() { lock.lock(); cancelled = true; if fd >= 0 { shutdown(fd, SHUT_RDWR) }; lock.unlock() }
        func close() { lock.lock(); if fd >= 0 { Darwin.close(fd); fd = -1 }; lock.unlock() }
    }

    /// - Parameter peerCheck: called with the peer's PID and UID right after connecting; return false to refuse.
    static func request(socketPath: String, method: String, path: String, headers: [(String, String)], body: Data?,
                        timeout: TimeInterval, peerCheck: @escaping @Sendable (pid_t, uid_t) -> Bool) async throws -> Response {
        let conn = Conn()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Response, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { conn.close() }
                    do { k.resume(returning: try perform(conn, socketPath, method, path, headers, body, timeout, peerCheck)) }
                    catch { k.resume(throwing: conn.cancelled ? URLError(.cancelled) : error) }
                }
            }
        } onCancel: { conn.cancel() }
    }

    static func perform(_ conn: Conn, _ socketPath: String, _ method: String, _ path: String, _ headers: [(String, String)],
                        _ body: Data?, _ timeout: TimeInterval, _ peerCheck: (pid_t, uid_t) -> Bool) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectFailed(errno: errno) }
        conn.lock.lock(); conn.fd = fd; let cancelled = conn.cancelled; conn.lock.unlock()
        if cancelled { throw URLError(.cancelled) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SnapTransError("EngineExited", 0, "socket path") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { throw ConnectFailed(errno: errno) }

        // The connection is ours only if the process at the other end is the tracked child, running as this user.
        var peer: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &len) == 0 else { throw SnapTransError("EngineUnexpectedResponse", "peer") }
        var euid: uid_t = 0, egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0, peerCheck(peer, euid) else { throw SnapTransError("EngineUnexpectedResponse", "peer") }

        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAccept: application/json\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        try writeAll(fd, out, conn)

        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if Date() > deadline { throw URLError(.timedOut) }
            if n > 0 {
                data.append(contentsOf: buf[0..<n])
                if data.count > maxResponse { throw SnapTransError("EngineUnexpectedResponse", "size") }
                if let r = try? parse(data, complete: false) { return r }
                continue
            }
            if n == 0 { break }
            if errno == EINTR { continue }
            if conn.cancelled { throw URLError(.cancelled) }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw URLError(.timedOut) }
            throw URLError(.networkConnectionLost)
        }
        return try parse(data, complete: true)
    }

    static func writeAll(_ fd: Int32, _ d: Data, _ conn: Conn) throws {
        var off = 0
        while off < d.count {
            let n = d.withUnsafeBytes { write(fd, $0.baseAddress! + off, d.count - off) }
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            if conn.cancelled { throw URLError(.cancelled) }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw URLError(.timedOut) }
            throw URLError(.networkConnectionLost)
        }
    }

    struct Incomplete: Error {}

    /// Parses a full response. With `complete: false`, throws `Incomplete` until the body is all there
    /// (Content-Length or the final chunk); with `complete: true` (EOF seen) a body without length ends at EOF.
    static func parse(_ data: Data, complete: Bool) throws -> Response {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else {
            if complete { throw SnapTransError("EngineUnexpectedResponse", "header") }
            throw Incomplete()
        }
        let headText = String(decoding: data[data.startIndex..<r.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else {
            throw SnapTransError("EngineUnexpectedResponse", "status")
        }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Data(data[r.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var body = Data()
            var i = rest.startIndex
            while true {
                guard let le = rest[i...].range(of: Data("\r\n".utf8)) else {
                    if complete { throw SnapTransError("EngineUnexpectedResponse", "chunk") }
                    throw Incomplete()
                }
                let sizeText = String(decoding: rest[i..<le.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    throw SnapTransError("EngineUnexpectedResponse", "chunk")
                }
                let start = le.upperBound
                if size == 0 { return Response(status: status, headers: headers, body: body) }
                guard rest.endIndex - start >= size + 2 else {
                    if complete { throw SnapTransError("EngineUnexpectedResponse", "chunk") }
                    throw Incomplete()
                }
                body.append(rest[start..<(start + size)])
                i = start + size + 2
            }
        }
        if let cl = headers["content-length"].flatMap({ Int($0) }) {
            guard rest.count >= cl else {
                if complete { throw SnapTransError("EngineUnexpectedResponse", "length") }
                throw Incomplete()
            }
            return Response(status: status, headers: headers, body: Data(rest.prefix(cl)))
        }
        if !complete { throw Incomplete() }
        return Response(status: status, headers: headers, body: rest)
    }
}
