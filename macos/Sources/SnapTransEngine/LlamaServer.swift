import Darwin
import Foundation
import Security
import SnapTransCore

/// "metal" (Apple GPU, all layers offloaded) or "cpu".
public enum ComputeBackend: String, Sendable { case metal, cpu }

/// What actually got loaded, and why it differs from what was requested (if it does).
public struct LoadedEngine: Sendable {
    public let modelPath: String
    public let selection: String
    public let backend: ComputeBackend
    public let fallbackReason: String?
    public let loadTime: TimeInterval
}

/// Where the bundled engine lives: <App>.app/Contents/Helpers/engine (llama-server + dylibs) and the guard in
/// Contents/Helpers. SNAPTRANS_ENGINE_DIR / SNAPTRANS_GUARD override them for development.
public struct EngineLocator: Sendable {
    public let engineFolder: String
    public let guardPath: String
    public init(engineFolder: String, guardPath: String) { self.engineFolder = engineFolder; self.guardPath = guardPath }

    public static func bundled() -> EngineLocator {
        let env = ProcessInfo.processInfo.environment
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path
        let exeDir = (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent }) ?? helpers
        let engine = env["SNAPTRANS_ENGINE_DIR"] ?? (helpers as NSString).appendingPathComponent("engine")
        var guardPath = env["SNAPTRANS_GUARD"] ?? (helpers as NSString).appendingPathComponent("snaptrans-engine-guard")
        if !FileManager.default.isExecutableFile(atPath: guardPath) { guardPath = (exeDir as NSString).appendingPathComponent("snaptrans-engine-guard") }
        return EngineLocator(engineFolder: engine, guardPath: guardPath)
    }

    public var serverPath: String { (engineFolder as NSString).appendingPathComponent("llama-server") }
}

/// One llama-server child process bound to 127.0.0.1 on a random port with a random API key (passed through the
/// environment, never the command line). It runs under snaptrans-engine-guard so it never outlives the app.
/// Nothing is sent until 127.0.0.1:port is proven to be our child. Not thread-safe: PlamoTranslator serializes access.
public final class LlamaServer: @unchecked Sendable {
    let locator: EngineLocator
    var guardProcess: Process?
    var serverPid: pid_t = 0
    var session: URLSession?
    var apiKey = ""
    var port = 0
    let stderrState = StderrState()
    public private(set) var loaded: LoadedEngine?
    public var diagnostic: (@Sendable (String) -> Void)?

    static let healthTimeout: TimeInterval = 3
    static let completionTimeout: TimeInterval = 120
    static let portAttempts = 4

    public init(locator: EngineLocator) { self.locator = locator }

    public var isRunning: Bool { guardProcess?.isRunning == true && serverPid > 0 && kill(serverPid, 0) == 0 }

    final class StderrState: @unchecked Sendable {
        let lock = NSLock()
        var offloaded = false, bindFailed = false, cause = ""
        func reset() { lock.lock(); offloaded = false; bindFailed = false; cause = ""; lock.unlock() }
        func scan(_ line: Substring) {
            let l = line.lowercased()
            lock.lock(); defer { lock.unlock() }
            if l.range(of: #"offloaded [1-9]\d*/"#, options: .regularExpression) != nil { offloaded = true }
            if l.contains("couldn't bind") || l.contains("failed to bind") || l.contains("address already in use") || l.contains("bind() failed") { bindFailed = true; cause = "bind failed" }
            else if l.contains("out of memory") || l.contains("failed to allocate") { cause = "out of memory" }
            else if l.contains("failed to load model") || l.contains("error loading model") { cause = "model load failed" }
        }
        var snapshot: (Bool, Bool, String) { lock.lock(); defer { lock.unlock() }; return (offloaded, bindFailed, cause) }
    }

    public func stop() {
        stopProcess()
        loaded = nil
    }

    func stopProcess() {
        if let g = guardProcess {
            // The guard forwards SIGTERM to llama-server and waits for it (SIGKILL after 5 s).
            if g.isRunning { g.terminate(); g.waitUntilExit() }
            guardProcess = nil
        }
        if serverPid > 0, kill(serverPid, 0) == 0, PortOwner.parent(of: serverPid) == 1 { kill(serverPid, SIGKILL) }
        serverPid = 0
        session?.invalidateAndCancel(); session = nil
        apiKey = ""; port = 0
    }

    /// - Parameter selection: "auto" (Metal, CPU fallback), "metal" or "cpu".
    public func load(modelPath: String, selection: String, guardModel: (() throws -> Void)?) async throws -> LoadedEngine {
        if let current = loaded, current.modelPath == modelPath, current.selection == selection, isRunning { return current }
        stop()
        do {
            try guardModel?()
            try EngineIntegrity.verify(folder: locator.engineFolder)
            let t0 = Date()
            var reason: String?
            if selection != "cpu" {
                do {
                    try await start(modelPath: modelPath, backend: .metal)
                    let l = LoadedEngine(modelPath: modelPath, selection: selection, backend: .metal, fallbackReason: nil, loadTime: Date().timeIntervalSince(t0))
                    loaded = l; return l
                } catch let e as SnapTransError {
                    if Task.isCancelled { throw CancellationError() }
                    reason = e.code + (e.args.isEmpty ? "" : ": " + e.args.joined(separator: " "))
                    diagnostic?("Metal load failed: \(reason!); falling back to CPU")
                    stopProcess()
                }
            }
            try await start(modelPath: modelPath, backend: .cpu)
            let l = LoadedEngine(modelPath: modelPath, selection: selection, backend: .cpu, fallbackReason: reason, loadTime: Date().timeIntervalSince(t0))
            loaded = l; return l
        } catch {
            stop()
            throw error
        }
    }

    func start(modelPath: String, backend: ComputeBackend) async throws {
        // A free port can be taken by another process between probing and llama-server's bind: retry with a new port.
        var attempt = 1
        while true {
            let p = try Self.freeLoopbackPort()
            do {
                try await start(modelPath: modelPath, backend: backend, port: p)
                if attempt > 1 { diagnostic?("llama-server started on port \(p) (attempt \(attempt))") }
                return
            } catch let e as SnapTransError where e.code == "PortInUse" && attempt < Self.portAttempts {
                diagnostic?("port \(p) unavailable, retrying with a new port")
                stopProcess()
                attempt += 1
            }
        }
    }

    static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SnapTransError("PortInUse", 0, "socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw SnapTransError("PortInUse", 0, "bind") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start(modelPath: String, backend: ComputeBackend, port p: Int) async throws {
        let token = Self.randomKey()
        var args = [String(getpid()), locator.serverPath,
                    "-m", modelPath, "-c", "4096", "-np", "1", "--host", "127.0.0.1", "--port", String(p),
                    "--no-webui", "--offline", "--verbosity", "4"]
        args += backend == .metal ? ["--device", "MTL0", "-ngl", "999"] : ["--device", "none", "-ngl", "0", "--no-op-offload"]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: locator.guardPath)
        proc.arguments = args
        // The key goes through the environment, not the command line (which other processes can read).
        var env = ["LLAMA_API_KEY": token, "PATH": "/usr/bin:/bin"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: locator.engineFolder)
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err; proc.standardInput = FileHandle.nullDevice
        stderrState.reset()
        let state = stderrState
        let diag = diagnostic
        final class Buffer: @unchecked Sendable { var data = Data() }
        let pending = Buffer()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            pending.data.append(d)
            while let nl = pending.data.firstIndex(of: 0x0A) {
                let line = String(decoding: pending.data[pending.data.startIndex..<nl], as: UTF8.self)
                pending.data.removeSubrange(pending.data.startIndex...nl)
                state.scan(Substring(line))
                if ProcessInfo.processInfo.environment["SNAPTRANS_ENGINE_LOG"] == "1" { diag?("llama: " + line) }
            }
        }
        try proc.run()
        guardProcess = proc
        // The guard prints "pid <n>" once llama-server is spawned.
        let pidLine = try await Self.readLine(out.fileHandleForReading, timeout: 10)
        guard pidLine.hasPrefix("pid "), let pid = pid_t(pidLine.dropFirst(4)) else { throw SnapTransError("EngineExited", proc.isRunning ? -1 : Int(proc.terminationStatus), "guard") }
        serverPid = pid

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]   // never through a proxy
        config.timeoutIntervalForRequest = Self.completionTimeout
        config.httpShouldSetCookies = false
        let s = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        session = s
        let base = URL(string: "http://127.0.0.1:\(p)")!
        let t0 = Date()
        var checkedOthers = false
        while true {
            try Task.checkCancellation()
            let (offloaded, bindFailed, cause) = stderrState.snapshot
            if !proc.isRunning || kill(pid, 0) != 0 {
                proc.waitUntilExit()
                if stderrState.snapshot.1 { throw SnapTransError("PortInUse", p, "bind failed") }
                throw SnapTransError("EngineExited", Int(proc.terminationStatus), stderrState.snapshot.2.isEmpty ? cause : stderrState.snapshot.2)
            }
            _ = offloaded
            if bindFailed { throw SnapTransError("PortInUse", p, "bind failed") }
            if Date().timeIntervalSince(t0) > 300 { throw SnapTransError("EngineTimeout") }
            // Nothing is sent until the listener on 127.0.0.1:port is proven to be our child process.
            if Self.childListens(pid, port: p) {
                if !checkedOthers {
                    if PortOwner.listeners(port: p).contains(where: { $0 != pid }) { throw SnapTransError("PortInUse", p, "another process is listening") }
                    guard PortOwner.parent(of: pid) == proc.processIdentifier,
                          let exe = PortOwner.executablePath(of: pid),
                          URL(fileURLWithPath: exe).resolvingSymlinksInPath().path == URL(fileURLWithPath: locator.serverPath).resolvingSymlinksInPath().path
                    else { throw SnapTransError("EngineUnexpectedResponse", "pid") }
                    checkedOthers = true
                }
                var req = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: Self.healthTimeout)
                req.httpMethod = "GET"
                if let (data, resp) = try? await s.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["status"] as? String == "ok" {
                    port = p; apiKey = token
                    // The key is only sent to the verified child; a wrong answer means it is not a llama-server.
                    let (pd, pr) = try await send("GET", "props", body: nil, timeout: Self.healthTimeout)
                    guard pr.statusCode == 200, let props = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
                          props["default_generation_settings"] != nil else { throw SnapTransError("EngineUnexpectedResponse", pr.statusCode) }
                    break
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        if backend == .metal && !stderrState.snapshot.0 { throw SnapTransError("NotOffloaded") }
    }

    static func childListens(_ pid: pid_t, port: Int) -> Bool {
        PortOwner.listeners(of: pid).contains { $0.0 == "127.0.0.1" && $0.1 == port }
    }

    static func readLine(_ h: FileHandle, timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask {
                var data = Data()
                while true {
                    let c = try h.read(upToCount: 1) ?? Data()
                    if c.isEmpty || c[0] == 0x0A { return String(decoding: data, as: UTF8.self) }
                    data.append(c)
                }
            }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); throw SnapTransError("EngineTimeout") }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    /// Sends an authenticated request only while 127.0.0.1:port is still owned by our running child.
    func send(_ method: String, _ path: String, body: Data?, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let s = session, isRunning, !apiKey.isEmpty, Self.childListens(serverPid, port: port) else { throw SnapTransError("EngineNotLoaded") }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, r) = try await s.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw SnapTransError("EngineUnexpectedResponse", 0) }
        return (d, http)
    }

    public func complete(prompt: String, stop: [String], maxTokens: Int) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "temperature": 0, "n_predict": maxTokens, "stop": stop, "cache_prompt": false] as [String: Any])
        let (d, r): (Data, HTTPURLResponse)
        do { (d, r) = try await send("POST", "completion", body: body, timeout: Self.completionTimeout) }
        catch let e as URLError where e.code == .timedOut { throw SnapTransError("TranslateTimeout") }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        guard r.statusCode == 200 else { throw SnapTransError("TranslateHttp", r.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let content = obj["content"] as? String
        else { throw SnapTransError("EngineUnexpectedResponse", r.statusCode) }
        if obj["stop_type"] as? String == "limit" { throw SnapTransError("TooLong") }
        return content
    }
}

/// Async mutual exclusion (FIFO).
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}

/// Translator over PLaMo 3 Translate. Loads lazily and serializes access to the server. `reset` cancels in-flight
/// work, waits for it to leave the server and applies a new configuration (model / device).
public final class PlamoTranslator: @unchecked Sendable {
    let server: LlamaServer
    let gate = AsyncGate()
    private let lock = NSLock()
    private var modelPath = "", selection = "auto"
    private var guardModel: (@Sendable () throws -> Void)?
    private var currentWork: (() -> Void)?
    private var generation = 0
    public private(set) var isShutDown = false

    public init(locator: EngineLocator) { server = LlamaServer(locator: locator) }

    func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    public var diagnostic: (@Sendable (String) -> Void)? { get { server.diagnostic } set { server.diagnostic = newValue } }
    public var loaded: LoadedEngine? { server.loaded }
    /// Called before a load with the backend about to be tried (for "Loading model (Metal)…").
    public var loading: (@Sendable (ComputeBackend) -> Void)?

    public func configure(modelPath: String, selection: String, guardModel: (@Sendable () throws -> Void)?) {
        sync { self.modelPath = modelPath; self.selection = selection; self.guardModel = guardModel }
    }

    func locked<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        if isShutDown { throw CancellationError() }
        let gen = sync { generation }
        await gate.enter()
        do {
            if sync({ gen != generation }) { throw CancellationError() }
            try Task.checkCancellation()
            let work = Task { try await body() }
            sync { currentWork = { work.cancel() } }
            let r = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            sync { currentWork = nil }
            await gate.leave()
            return r
        } catch {
            sync { currentWork = nil }
            await gate.leave()
            throw error
        }
    }

    @discardableResult
    public func ensureLoaded() async throws -> LoadedEngine {
        try await locked { [self] in
            let (path, sel, g) = sync { (modelPath, selection, guardModel) }
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { throw SnapTransError("NoModel") }
            if !server.isRunning || server.loaded?.modelPath != path || server.loaded?.selection != sel {
                loading?(sel == "cpu" ? .cpu : .metal)
            }
            return try await server.load(modelPath: path, selection: sel, guardModel: g)
        }
    }

    public func translate(_ text: String, from: String = "", to: String) async throws -> (text: String, elapsed: TimeInterval) {
        let prompt = try PlamoPrompt.build(source: text, from: from, to: to)
        try await ensureLoaded()
        return try await locked { [self] in
            let t0 = Date()
            let out = try await server.complete(prompt: prompt, stop: PlamoPrompt.stopTokens, maxTokens: 2048)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { throw SnapTransError("EmptyResult") }
            return (out, Date().timeIntervalSince(t0))
        }
    }

    /// Invalidates queued work, cancels running work, waits until it has left the server, stops it and applies the new configuration.
    public func reset(modelPath: String? = nil, selection: String? = nil) async {
        let cancel = sync { generation += 1; return currentWork }
        cancel?()
        await gate.enter()
        server.stop()
        sync { if let m = modelPath { self.modelPath = m }; if let s = selection { self.selection = s } }
        await gate.leave()
    }

    public func shutdown() async {
        isShutDown = true
        let cancel = sync { generation += 1; return currentWork }
        cancel?()
        server.stop()
    }
}
