using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;
using SnapTrans.Core;

namespace SnapTrans.Llama;

/// <summary>What actually got loaded, and why it differs from what was requested (if it does).</summary>
public sealed record LoadedEngine(string ModelPath, string Selection, ComputeDevice Device, string? FallbackReason, TimeSpan LoadTime);

/// <summary>
/// One llama-server child process bound to 127.0.0.1 on a random port with a random API key.
/// The process is tied to a job object so it never outlives the app.
/// Not thread-safe: <see cref="PlamoTranslator"/> serializes all access.
/// </summary>
public sealed class LlamaServer : IDisposable
{
    readonly EngineLocator locator;
    Process? process;
    ChildLifetime? lifetime;
    HttpClient? client;
    // Only fixed category words derived from llama-server's stderr are kept (never the raw text: it contains paths).
    volatile string exitCause = "";
    readonly List<IDisposable> pins = [];
    string apiKey = "";
    int port;

    static readonly TimeSpan HealthTimeout = TimeSpan.FromSeconds(3);
    static readonly TimeSpan CompletionTimeout = TimeSpan.FromMinutes(2);
    const int PortAttempts = 4;

    public LlamaServer(EngineLocator locator) => this.locator = locator;

    public LoadedEngine? Loaded { get; private set; }
    public bool IsRunning => process is { HasExited: false };

    /// <summary>Diagnostics for the app log (port retries, fallbacks).</summary>
    public event Action<string>? Diagnostic;

    public void Dispose()
    {
        if (process != null) {
            try { if (!process.HasExited) { process.Kill(true); process.WaitForExit(5000); } } catch (InvalidOperationException) { }
            process.Dispose(); process = null;
        }
        lifetime?.Dispose(); lifetime = null;
        client?.Dispose(); client = null;
        foreach (var pin in pins) pin.Dispose();
        pins.Clear();
        apiKey = ""; port = 0;
        Loaded = null;
    }

    /// <param name="selection">"auto", "cpu", or a <see cref="ComputeDevice.Key"/>.</param>
    /// <param name="modelGuard">
    /// Optional check of the model file, given a read handle that denies writers; the handle stays open until the server
    /// stops, so the verified bytes are the ones llama-server maps.
    /// </param>
    public async Task<LoadedEngine> LoadAsync(string modelPath, string selection, IProgress<ComputeDevice>? progress, CancellationToken ct,
        Func<FileStream, CancellationToken, Task>? modelGuard = null)
    {
        if (Loaded is { } current && current.ModelPath == modelPath && current.Selection == selection && IsRunning) return current;
        Dispose();
        try {
            if (modelGuard != null) {
                var model = new FileStream(modelPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.Asynchronous | FileOptions.SequentialScan);
                pins.Add(model);
                await modelGuard(model, ct);
            }
            var sw = Stopwatch.StartNew();
            ComputeDevice? gpu = null;
            string? reason = null;
            if (selection != "cpu") {
                var catalog = await locator.DiscoverAsync(ct);
                gpu = selection == "auto" ? catalog.BestGpu : catalog.Devices.FirstOrDefault(d => d.Key == selection);
                if (gpu == null && selection != "auto") reason = "DeviceNotFound";
            }
            if (gpu != null) {
                try {
                    progress?.Report(gpu);
                    await StartAsync(modelPath, gpu, ct);
                    return Loaded = new(modelPath, selection, gpu, null, sw.Elapsed);
                } catch (Exception ex) when (!ct.IsCancellationRequested) {
                    // Fall back to CPU once and keep the reason for the UI.
                    reason = ex is SnapTransException se ? se.Code + (se.Args.Length > 0 ? ": " + string.Join(" ", se.Args) : "") : ex.GetType().Name; // never raw messages (paths)
                    Diagnostic?.Invoke($"GPU load failed ({gpu.BackendLabel}): {reason}; falling back to CPU");
                    StopProcess();
                }
            }
            progress?.Report(ComputeDevice.Cpu);

            await StartAsync(modelPath, ComputeDevice.Cpu, ct);
            return Loaded = new(modelPath, selection, ComputeDevice.Cpu, reason, sw.Elapsed);
        } catch {
            // Never leave a half-started server behind (CPU failure, cancellation, timeout).
            Dispose();
            throw;
        }
    }

    /// <summary>Test hook: the first start uses this port (e.g. one already taken) to exercise the retry path.</summary>
    static int? DebugFirstPort => int.TryParse(Environment.GetEnvironmentVariable("SNAPTRANS_DEBUG_FIRST_PORT"), out var p) ? p : null;
    bool debugPortUsed;

    async Task StartAsync(string modelPath, ComputeDevice device, CancellationToken ct)
    {
        // A free port can be taken by another process between probing and llama-server's bind: retry with a new port.
        for (int attempt = 1; ; attempt++) {
            int port;
            if (!debugPortUsed && DebugFirstPort is { } forced) { port = forced; debugPortUsed = true; }
            else {
                using var probe = new TcpListener(IPAddress.Loopback, 0);
                probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
            }
            try {
                await StartOnPortAsync(modelPath, device, port, ct);
                if (attempt > 1) Diagnostic?.Invoke($"llama-server started on port {port} (attempt {attempt})");
                return;
            } catch (SnapTransException ex) when (ex.Code == "PortInUse" && attempt < PortAttempts) {
                Diagnostic?.Invoke($"port {port} unavailable ({(ex.Args.Length > 1 ? ex.Args[1] : "bind")}), retrying with a new port");
                StopProcess();
            }
        }
    }

    /// <summary>Stops only the child process (keeps the model pin for a CPU retry on the same file).</summary>
    void StopProcess()
    {
        if (process != null) {
            try { if (!process.HasExited) { process.Kill(true); process.WaitForExit(5000); } } catch (InvalidOperationException) { }
            process.Dispose(); process = null;
        }
        lifetime?.Dispose(); lifetime = null;
        client?.Dispose(); client = null;
        apiKey = ""; port = 0;
    }

    async Task StartOnPortAsync(string modelPath, ComputeDevice device, int port, CancellationToken ct)
    {
        var token = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(16));
        var (info, enginePins) = await locator.PrepareAsync(device.Backend, ct);
        pins.Add(enginePins);
        foreach (var arg in new[] { "-m", modelPath, "-c", "4096", "-np", "1", "--host", "127.0.0.1", "--port", port.ToString(),
                     "--no-webui", "--no-agent", "--offline", "--verbosity", "4" })
            info.ArgumentList.Add(arg);
        // The key goes through the environment, not the command line (which other processes can read).
        info.Environment["LLAMA_API_KEY"] = token;
        bool gpu = device.Backend != "cpu";
        info.ArgumentList.Add("--device");
        if (gpu) {
            // Isolate the chosen adapter; inside the process it becomes index 0.
            info.Environment[device.Backend == "cuda" ? "CUDA_VISIBLE_DEVICES" : "GGML_VK_VISIBLE_DEVICES"] = device.Index.ToString();
            info.ArgumentList.Add(device.Backend == "cuda" ? "CUDA0" : "Vulkan0");
            foreach (var a in new[] { "-ngl", "999", "--split-mode", "none" }) info.ArgumentList.Add(a);
        } else {
            foreach (var a in new[] { "none", "-ngl", "0", "--no-op-offload" }) info.ArgumentList.Add(a);
        }
        bool offloaded = false, bindFailed = false;
        exitCause = "";
        process = new Process { StartInfo = info };
        process.ErrorDataReceived += (_, e) => {
            if (e.Data == null) return;
            if (Regex.IsMatch(e.Data, @"offloaded [1-9]\d*/")) Volatile.Write(ref offloaded, true);
            if (Regex.IsMatch(e.Data, @"couldn't bind|failed to bind|address already in use|bind\(\) failed", RegexOptions.IgnoreCase)) { Volatile.Write(ref bindFailed, true); exitCause = "bind failed"; }
            else if (Regex.IsMatch(e.Data, @"out of memory|failed to allocate|ErrorOutOfDeviceMemory", RegexOptions.IgnoreCase)) exitCause = "out of memory";
            else if (Regex.IsMatch(e.Data, @"failed to load model|error loading model", RegexOptions.IgnoreCase)) exitCause = "model load failed";
        };
        process.OutputDataReceived += (_, _) => { };
        process.Start();
        lifetime = new ChildLifetime(process.Handle);
        process.BeginErrorReadLine(); process.BeginOutputReadLine();
        client = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false }) { BaseAddress = new Uri($"http://127.0.0.1:{port}"), Timeout = Timeout.InfiniteTimeSpan };
        var timer = Stopwatch.StartNew();
        while (true) {
            ct.ThrowIfCancellationRequested();
            if (process.HasExited) {
                process.WaitForExit(); // drain stderr so the bind error is visible
                if (Volatile.Read(ref bindFailed)) throw new SnapTransException("PortInUse", port, "bind failed");
                throw new SnapTransException("EngineExited", process.ExitCode, exitCause);
            }
            if (Volatile.Read(ref bindFailed)) throw new SnapTransException("PortInUse", port, "bind failed");
            if (timer.Elapsed.TotalMinutes > 5) throw new SnapTransException("EngineTimeout");
            // Nothing is sent until the listener on 127.0.0.1:port is proven to be our child process.
            var owners = PortOwner.ListenersOf(IPAddress.Loopback, port);
            if (owners.Any(pid => pid != process.Id)) throw new SnapTransException("PortInUse", port, "another process is listening");
            if (owners.Count > 0) {
                using var probe = CancellationTokenSource.CreateLinkedTokenSource(ct);
                probe.CancelAfter(HealthTimeout);
                try {
                    using var health = await client.GetAsync("/health", probe.Token);   // public endpoint: no key
                    if (health.StatusCode == HttpStatusCode.OK && IsHealthy(await health.Content.ReadAsStringAsync(probe.Token))) {
                        this.port = port; apiKey = token;
                        // The key is only sent to the verified child; a wrong answer means it is not a llama-server.
                        using var props = await SendAsync(HttpMethod.Get, "/props", null, probe.Token);
                        if (props.StatusCode != HttpStatusCode.OK || !LooksLikeProps(await props.Content.ReadAsStringAsync(probe.Token)))
                            throw new SnapTransException("EngineUnexpectedResponse", (int)props.StatusCode);
                        break;
                    }
                } catch (HttpRequestException) {
                } catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
            }
            await Task.Delay(150, ct);
        }
        if (gpu && !Volatile.Read(ref offloaded)) throw new SnapTransException("NotOffloaded");
    }

    static bool IsHealthy(string json)
    {
        try { using var doc = JsonDocument.Parse(json); return doc.RootElement.TryGetProperty("status", out var s) && s.GetString() == "ok"; }
        catch (JsonException) { return false; }
    }

    static bool LooksLikeProps(string json)
    {
        try { using var doc = JsonDocument.Parse(json); return doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("default_generation_settings", out _); }
        catch (JsonException) { return false; }
    }

    /// <summary>Sends an authenticated request only while 127.0.0.1:port is still owned by our running child.</summary>
    async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, HttpContent? content, CancellationToken ct)
    {
        if (client == null || process is not { HasExited: false } || apiKey == "") throw new SnapTransException("EngineNotLoaded");
        var owners = PortOwner.ListenersOf(IPAddress.Loopback, port);
        if (owners.Count == 0 || owners.Any(pid => pid != process.Id)) throw new SnapTransException("EngineNotLoaded");
        using var request = new HttpRequestMessage(method, path) { Content = content };
        request.Headers.Authorization = new("Bearer", apiKey);
        return await client.SendAsync(request, ct);
    }

    public async Task<string> CompleteAsync(string prompt, IReadOnlyList<string> stop, int maxTokens, CancellationToken ct)
    {
        if (client == null || !IsRunning) throw new SnapTransException("EngineNotLoaded");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(CompletionTimeout);
        try {
            using var response = await SendAsync(HttpMethod.Post, "/completion",
                JsonContent.Create(new { prompt, temperature = 0, n_predict = maxTokens, stop, cache_prompt = false }), timeout.Token);
            if (!response.IsSuccessStatusCode) throw new SnapTransException("TranslateHttp", (int)response.StatusCode);
            JsonDocument doc;
            try { doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token)); }
            catch (JsonException) { throw new SnapTransException("EngineUnexpectedResponse", (int)response.StatusCode); }
            using var _ = doc;
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.String)
                throw new SnapTransException("EngineUnexpectedResponse", (int)response.StatusCode);
            if (root.TryGetProperty("stop_type", out var st) && st.GetString() == "limit") throw new SnapTransException("TooLong");
            return content.GetString() ?? "";
        } catch (OperationCanceledException) when (!ct.IsCancellationRequested) {
            throw new SnapTransException("TranslateTimeout");
        }
    }
}

/// <summary>
/// ITranslator over PLaMo 3 Translate. Loads lazily and serializes access to the server.
/// Every operation runs under the current "generation" token: <see cref="ResetAsync"/> cancels it, so a
/// device/model change never waits for a long load or translation and never blocks the caller's thread.
/// </summary>
public sealed class PlamoTranslator : ITranslator
{
    readonly LlamaServer server;
    readonly SemaphoreSlim gate = new(1, 1);
    string modelPath = "", selection = "auto";
    CancellationTokenSource generation = new();
    volatile bool shutDown;

    public PlamoTranslator(EngineLocator locator)
    {
        server = new LlamaServer(locator);
        server.Diagnostic += m => Diagnostic?.Invoke(m);
    }

    public event Action<ComputeDevice>? Loading;
    public event Action<string>? Diagnostic;
    public LoadedEngine? Loaded => server.Loaded;
    /// <summary>Checks the model file (read handle that denies writers, kept open while the server runs) before each load.</summary>
    public Func<FileStream, CancellationToken, Task>? ModelGuard { get; set; }
    public bool IsShutDown => shutDown;

    /// <summary>Test hook: a slow, non-cancellable step at the start of a load (milliseconds).</summary>
    static int DebugLoadDelay => int.TryParse(Environment.GetEnvironmentVariable("SNAPTRANS_DEBUG_LOAD_DELAY_MS"), out var ms) ? ms : 0;

    /// <summary>Only for the initial configuration; later changes go through <see cref="ResetAsync"/>.</summary>
    public void Configure(string modelPath, string selection)
    {
        this.modelPath = modelPath; this.selection = selection;
    }

    async Task<T> Locked<T>(Func<CancellationToken, Task<T>> body, CancellationToken ct)
    {
        if (shutDown) throw new OperationCanceledException();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, Volatile.Read(ref generation).Token);
        await gate.WaitAsync(linked.Token);
        try {
            linked.Token.ThrowIfCancellationRequested();
            return await body(linked.Token);
        } finally { gate.Release(); }
    }

    public Task<LoadedEngine> EnsureLoadedAsync(CancellationToken ct) => Locked(async t => {
        if (modelPath == "" || !File.Exists(modelPath)) throw new SnapTransException("NoModel");
        if (DebugLoadDelay > 0 && !server.IsRunning) await Task.Delay(DebugLoadDelay, CancellationToken.None);
        return await server.LoadAsync(modelPath, selection, new Progress<ComputeDevice>(d => Loading?.Invoke(d)), t, ModelGuard);
    }, ct);

    public async Task<TranslationResult> TranslateAsync(TranslationRequest request, CancellationToken ct)
    {
        var prompt = PlamoPrompt.Build(request.Text, request.From, request.To);
        await EnsureLoadedAsync(ct);
        return await Locked(async t => {
            var sw = Stopwatch.StartNew();
            var text = (await server.CompleteAsync(prompt, PlamoPrompt.StopTokens, 2048, t)).Trim();
            if (text.Length == 0) throw new SnapTransException("EmptyResult");
            return new TranslationResult(text, request.From, request.To, sw.Elapsed);
        }, ct);
    }

    /// <summary>
    /// Cancels in-flight work, waits asynchronously until it has left the server, stops the server and
    /// applies the new configuration before anything can load again.
    /// </summary>
    public async Task ResetAsync(string? newModelPath = null, string? newSelection = null)
    {
        if (shutDown) return;
        var old = Interlocked.Exchange(ref generation, new CancellationTokenSource());
        old.Cancel();
        await gate.WaitAsync();
        try {
            server.Dispose();
            if (newModelPath != null) modelPath = newModelPath;
            if (newSelection != null) selection = newSelection;
        } finally { gate.Release(); old.Dispose(); }
    }

    /// <summary>App exit: cancel, wait up to <paramref name="wait"/> for running work to leave, then stop the server.</summary>
    public async Task ShutdownAsync(TimeSpan wait)
    {
        shutDown = true;
        Volatile.Read(ref generation).Cancel();
        bool entered = await gate.WaitAsync(wait);
        try { server.Dispose(); }
        finally { if (entered) gate.Release(); }
    }
}
