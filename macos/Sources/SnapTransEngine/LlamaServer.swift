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
/// Contents/Helpers. Test builds (SNAPTRANS_TEST_HOOKS) also accept SNAPTRANS_ENGINE_DIR / SNAPTRANS_GUARD overrides.
public struct EngineLocator: Sendable {
    public let engineFolder: String
    public let guardPath: String
    public init(engineFolder: String, guardPath: String) { self.engineFolder = engineFolder; self.guardPath = guardPath }

    public static func bundled() -> EngineLocator {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path
        var engine = (helpers as NSString).appendingPathComponent("engine")
        var guardPath = (helpers as NSString).appendingPathComponent("snaptrans-engine-guard")
        #if SNAPTRANS_TEST_HOOKS
        let env = ProcessInfo.processInfo.environment
        let exeDir = (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent }) ?? helpers
        if let e = env["SNAPTRANS_ENGINE_DIR"] { engine = e }
        if let g = env["SNAPTRANS_GUARD"] { guardPath = g }
        if !FileManager.default.isExecutableFile(atPath: guardPath) { guardPath = (exeDir as NSString).appendingPathComponent("snaptrans-engine-guard") }
        #endif
        return EngineLocator(engineFolder: engine, guardPath: guardPath)
    }

    public var serverPath: String { (engineFolder as NSString).appendingPathComponent("llama-server") }
}

/// The model file handed to the engine: a verified, owner-only copy (see ModelStore.pinnedModel).
public typealias ModelPreparer = @Sendable (_ privateFolder: String) throws -> PinnedModel

/// One llama-server child process listening on a Unix domain socket in a fresh owner-only (0700) folder, with a random
/// API key (passed through the environment, never the command line). It runs under snaptrans-engine-guard so it never
/// outlives the app. Every request connects anew and checks that the peer of that connection is the tracked child
/// (PID + start time) before the key or any text is written. Not thread-safe: PlamoTranslator serializes access.
public final class LlamaServer: @unchecked Sendable {
    let locator: EngineLocator
    var guardProcess: Process?
    var server: ProcessIdentity?
    var runFolder: String?
    var socketPath = ""
    var apiKey = ""
    var pinned: PinnedModel?
    let stderrState = StderrState()
    public private(set) var loaded: LoadedEngine?
    public var diagnostic: (@Sendable (String) -> Void)?

    static let healthTimeout: TimeInterval = 3
    static let completionTimeout: TimeInterval = 120

    public init(locator: EngineLocator) { self.locator = locator }

    public var isRunning: Bool { guardProcess?.isRunning == true && server?.isAlive == true }

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
        // Only the tracked child itself (same PID *and* start time, now orphaned) is ever killed here.
        if let s = server, s.isAlive, PortOwner.parent(of: s.pid) == 1 { kill(s.pid, SIGKILL) }
        server = nil
        pinned = nil
        if let dir = runFolder { try? FileManager.default.removeItem(atPath: dir) }
        runFolder = nil
        socketPath = ""; apiKey = ""
    }

    /// - Parameter selection: "auto" (Metal, CPU fallback), "metal" or "cpu".
    public func load(modelPath: String, selection: String, prepare: ModelPreparer?) async throws -> LoadedEngine {
        if let current = loaded, current.modelPath == modelPath, current.selection == selection, isRunning { return current }
        stop()
        do {
            try EngineIntegrity.verify(folder: locator.engineFolder, guardPath: locator.guardPath)
            let t0 = Date()
            var reason: String?
            if selection != "cpu" {
                do {
                    try await start(modelPath: modelPath, backend: .metal, prepare: prepare)
                    let l = LoadedEngine(modelPath: modelPath, selection: selection, backend: .metal, fallbackReason: nil, loadTime: Date().timeIntervalSince(t0))
                    loaded = l; return l
                } catch let e as SnapTransError {
                    if Task.isCancelled { throw CancellationError() }
                    if e.code == "ExistingHashMismatch" || e.code == "EngineTampered" || e.code == "ModelMissing" { throw e }
                    reason = e.code + (e.args.isEmpty ? "" : ": " + e.args.joined(separator: " "))
                    diagnostic?("Metal load failed: \(e.safeDescription); falling back to CPU")
                    stopProcess()
                }
            }
            try await start(modelPath: modelPath, backend: .cpu, prepare: prepare)
            let l = LoadedEngine(modelPath: modelPath, selection: selection, backend: .cpu, fallbackReason: reason, loadTime: Date().timeIntervalSince(t0))
            loaded = l; return l
        } catch {
            stop()
            throw error
        }
    }

    /// 32 hex characters from the system CSPRNG; startup is aborted if it fails.
    static func randomKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SnapTransError("EngineExited", 0, "random") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh owner-only folder for the socket and the pinned model (mkdtemp creates it as 0700) in the per-user
    /// temporary folder, which is itself private to this user.
    static func makeRunFolder() throws -> String {
        removeStaleRunFolders()
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("snaptrans.XXXXXX")
        var template = Array(base.utf8CString)
        guard let p = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else { throw SnapTransError("EngineExited", 0, "run folder") }
        let dir = String(cString: p)
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else {
            throw SnapTransError("EngineExited", 0, "run folder")
        }
        // Owner record, so a later start can remove the folder if this process dies without cleaning up.
        try? PrivateFiles.write(Data("\(getpid()) \(ProcessIdentity.of(getpid())?.startSec ?? 0)".utf8), to: URL(fileURLWithPath: dir).appendingPathComponent("owner"))
        return dir
    }

    /// Removes run folders (socket + model copy) left behind by a SnapTrans process that no longer runs (crash, kill).
    static func removeStaleRunFolders() {
        let tmp = NSTemporaryDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp) else { return }
        for n in names where n.hasPrefix("snaptrans.") && n.count == "snaptrans.XXXXXX".count {
            let dir = (tmp as NSString).appendingPathComponent(n)
            var st = stat()
            guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { continue }
            let owner = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent("owner"), encoding: .utf8))?.split(separator: " ")
            if let o = owner, o.count == 2, let pid = pid_t(o[0]), let start = UInt64(o[1]),
               let ident = ProcessIdentity.of(pid), ident.startSec == start { continue }   // its process still runs
            if owner == nil, Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 3600 { continue }   // being created
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    func start(modelPath: String, backend: ComputeBackend, prepare: ModelPreparer?) async throws {
        let token = try Self.randomKey()
        let dir = try Self.makeRunFolder()
        runFolder = dir
        let sock = (dir as NSString).appendingPathComponent("engine.sock")
        // The model is checked again right here and the engine gets the verified owner-only copy.
        let pin = try prepare?(dir)
        pinned = pin
        var args = [String(getpid()), locator.serverPath,
                    "-m", pin?.path ?? modelPath, "-c", "4096", "-np", "1", "--host", sock,
                    "--no-webui", "--offline", "--no-mmproj", "--no-slots", "--cache-ram", "0", "--no-cache-prompt",
                    // 4: the "offloaded N/M layers" line (Metal check) is a debug-level message. stderr is only
                    // scanned in memory for fixed conditions and never stored.
                    "--verbosity", "4"]
        args += backend == .metal ? ["--device", "MTL0", "-ngl", "999"] : ["--device", "none", "-ngl", "0", "--no-op-offload"]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: locator.guardPath)
        proc.arguments = args
        // The key goes through the environment, not the command line (which other processes can read). Nothing else
        // is inherited (no LLAMA_ARG_* from the user's environment).
        var env = ["LLAMA_API_KEY": token, "PATH": "/usr/bin:/bin"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err; proc.standardInput = FileHandle.nullDevice
        stderrState.reset()
        let state = stderrState
        #if SNAPTRANS_TEST_HOOKS
        let rawLog = ProcessInfo.processInfo.environment["SNAPTRANS_ENGINE_LOG"] == "1" ? diagnostic : nil
        #endif
        final class Buffer: @unchecked Sendable { var data = Data() }
        let pending = Buffer()
        // stderr is only scanned in memory for a few fixed conditions; it is never stored (test builds can opt in).
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            pending.data.append(d)
            while let nl = pending.data.firstIndex(of: 0x0A) {
                let line = String(decoding: pending.data[pending.data.startIndex..<nl], as: UTF8.self)
                pending.data.removeSubrange(pending.data.startIndex...nl)
                state.scan(Substring(line))
                #if SNAPTRANS_TEST_HOOKS
                rawLog?("llama: " + line)
                #endif
            }
        }
        try proc.run()
        guardProcess = proc
        // The guard prints "pid <n>" once llama-server is spawned.
        let pidLine = try await Self.readLine(out.fileHandleForReading, timeout: 10)
        guard pidLine.hasPrefix("pid "), let pid = pid_t(pidLine.dropFirst(4)) else { throw SnapTransError("EngineExited", proc.isRunning ? -1 : Int(proc.terminationStatus), "guard") }
        // Our child: spawned by our guard from the verified executable. Remember it by PID + start time.
        guard let ident = ProcessIdentity.of(pid), PortOwner.parent(of: pid) == proc.processIdentifier,
              let exe = PortOwner.executablePath(of: pid),
              URL(fileURLWithPath: exe).resolvingSymlinksInPath().path == URL(fileURLWithPath: locator.serverPath).resolvingSymlinksInPath().path
        else { throw SnapTransError("EngineUnexpectedResponse", "pid") }
        server = ident
        socketPath = sock

        let t0 = Date()
        while true {
            try Task.checkCancellation()
            let (_, bindFailed, cause) = stderrState.snapshot
            if !proc.isRunning || !ident.isAlive {
                proc.waitUntilExit()
                let c = stderrState.snapshot.2
                throw SnapTransError("EngineExited", Int(proc.terminationStatus), c.isEmpty ? cause : c)
            }
            if bindFailed { throw SnapTransError("EngineExited", 0, "bind failed") }
            if Date().timeIntervalSince(t0) > 300 { throw SnapTransError("EngineTimeout") }
            do {
                let health = try await raw("GET", "health", body: nil, timeout: Self.healthTimeout, authorized: false)
                if health.status == 200, let obj = try? JSONSerialization.jsonObject(with: health.body) as? [String: Any], obj["status"] as? String == "ok" {
                    apiKey = token
                    // A wrong answer with the key means it is not the llama-server we expect.
                    let props = try await raw("GET", "props", body: nil, timeout: Self.healthTimeout, authorized: true)
                    guard props.status == 200, let o = try? JSONSerialization.jsonObject(with: props.body) as? [String: Any],
                          o["default_generation_settings"] != nil else { throw SnapTransError("EngineUnexpectedResponse", props.status) }
                    break
                }
            } catch is UnixHTTP.ConnectFailed {
                // Not listening yet.
            } catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost {
                // Still loading.
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        if backend == .metal && !stderrState.snapshot.0 { throw SnapTransError("NotOffloaded") }
        // The engine has the model open; the private copy can go (frees nothing on APFS, avoids leftovers).
        try pin?.afterLoad()
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

    /// One request on a new connection whose peer must be the tracked child (checked on that connection).
    func raw(_ method: String, _ path: String, body: Data?, timeout: TimeInterval, authorized: Bool) async throws -> UnixHTTP.Response {
        guard let ident = server, !socketPath.isEmpty, guardProcess?.isRunning == true else { throw SnapTransError("EngineNotLoaded") }
        var headers: [(String, String)] = []
        if authorized {
            guard !apiKey.isEmpty else { throw SnapTransError("EngineNotLoaded") }
            headers.append(("Authorization", "Bearer \(apiKey)"))
        }
        if body != nil { headers.append(("Content-Type", "application/json")) }
        let uid = getuid()
        return try await UnixHTTP.request(socketPath: socketPath, method: method, path: "/" + path, headers: headers, body: body,
                                          timeout: timeout) { peer, peerUid in
            peer == ident.pid && peerUid == uid && ident.isAlive
        }
    }

    /// Sends an authenticated request to the running child.
    func send(_ method: String, _ path: String, body: Data?, timeout: TimeInterval) async throws -> UnixHTTP.Response {
        guard isRunning else { throw SnapTransError("EngineNotLoaded") }
        return try await raw(method, path, body: body, timeout: timeout, authorized: true)
    }

    public func complete(prompt: String, stop: [String], maxTokens: Int) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "temperature": 0, "n_predict": maxTokens, "stop": stop, "cache_prompt": false] as [String: Any])
        let r: UnixHTTP.Response
        do { r = try await send("POST", "completion", body: body, timeout: Self.completionTimeout) }
        catch let e as URLError where e.code == .timedOut { throw SnapTransError("TranslateTimeout") }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch is UnixHTTP.ConnectFailed { throw SnapTransError("EngineNotLoaded") }
        guard r.status == 200 else { throw SnapTransError("TranslateHttp", r.status) }
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let content = obj["content"] as? String
        else { throw SnapTransError("EngineUnexpectedResponse", r.status) }
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
    private var prepare: ModelPreparer?
    private var currentWork: (() -> Void)?
    private var generation = 0
    public private(set) var isShutDown = false

    public init(locator: EngineLocator) { server = LlamaServer(locator: locator) }

    func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    public var diagnostic: (@Sendable (String) -> Void)? { get { server.diagnostic } set { server.diagnostic = newValue } }
    public var loaded: LoadedEngine? { server.loaded }
    /// Called before a load with the backend about to be tried (for "Loading model (Metal)…").
    public var loading: (@Sendable (ComputeBackend) -> Void)?

    /// `prepare` checks the model right before each engine start and returns the verified copy the engine gets.
    public func configure(modelPath: String, selection: String, prepare: ModelPreparer?) {
        sync { self.modelPath = modelPath; self.selection = selection; self.prepare = prepare }
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
            let (path, sel, g) = sync { (modelPath, selection, prepare) }
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { throw SnapTransError("NoModel") }
            if !server.isRunning || server.loaded?.modelPath != path || server.loaded?.selection != sel {
                loading?(sel == "cpu" ? .cpu : .metal)
            }
            return try await server.load(modelPath: path, selection: sel, prepare: g)
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
