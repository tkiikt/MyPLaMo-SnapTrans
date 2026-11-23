using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;

namespace SnapTrans.Llama;

/// <summary>A llama.cpp backend device. Key is stable across driver re-enumeration (backend + name + occurrence).</summary>
public sealed record ComputeDevice(string Key, string Backend, string Name, int Index, bool Integrated, long MemoryMiB, int Ordinal = 0)
{
    public static ComputeDevice Cpu { get; } = new("cpu", "cpu", "CPU", 0, false, 0);
    public string BackendLabel => Backend switch { "cuda" => "CUDA", "vulkan" => "Vulkan", _ => "CPU" };
    public string Label => Backend == "cpu" ? "CPU" : $"{Name}{(Ordinal > 0 ? $" #{Ordinal + 1}" : "")} ({BackendLabel})";
}

public sealed record DeviceCatalog(IReadOnlyList<ComputeDevice> Devices, IReadOnlyList<string> Errors, IReadOnlyList<string> Backends)
{
    /// <summary>Automatic choice: CUDA, then Vulkan (discrete before integrated), then CPU.</summary>
    public ComputeDevice? BestGpu => Devices
        .OrderBy(d => d.Integrated).ThenBy(d => d.Backend == "cuda" ? 0 : 1).ThenByDescending(d => d.MemoryMiB)
        .FirstOrDefault();
}

/// <summary>
/// Locates backend folders (engine/cpu, engine/vulkan, engine/cuda) across several roots,
/// e.g. the bundled engine next to the exe and a per-user folder for the optional CUDA engine.
/// </summary>
public sealed class EngineLocator(params string[] roots)
{
    public IReadOnlyList<string> Roots { get; } = roots;

    public string? FolderFor(string backend) => Roots
        .Select(r => Path.Combine(r, backend))
        .FirstOrDefault(d => File.Exists(Path.Combine(d, "llama-server.exe")) || File.Exists(Path.Combine(d, "llama-server")));

    public IReadOnlyList<string> InstalledBackends => new[] { "cpu", "vulkan", "cuda" }.Where(b => FolderFor(b) != null).ToArray();

    /// <summary>
    /// Start information for a backend, after its folder has been verified against the pinned release manifest
    /// (see <see cref="EngineIntegrity"/>). The returned disposable is a no-op: verified files stay pinned for the session.
    /// </summary>
    public async Task<(ProcessStartInfo Info, IDisposable Pins)> PrepareAsync(string backend, CancellationToken ct)
    {
        var directory = FolderFor(backend) ?? throw new Core.SnapTransException("EngineMissing", backend);
        await EngineIntegrity.EnsureVerifiedAsync(directory, backend, ct);
        return (StartInfo(backend), NoPins.Instance);
    }

    sealed class NoPins : IDisposable { public static readonly NoPins Instance = new(); public void Dispose() { } }

    ProcessStartInfo StartInfo(string backend)
    {
        var directory = FolderFor(backend) ?? throw new Core.SnapTransException("EngineMissing", backend);
        var exe = Path.Combine(directory, OperatingSystem.IsWindows() ? "llama-server.exe" : "llama-server");
        var info = new ProcessStartInfo(exe) {
            WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true
        };
        // Device indices must mean the same thing in discovery and inference.
        info.Environment.Remove("CUDA_VISIBLE_DEVICES");
        info.Environment.Remove("GGML_VK_VISIBLE_DEVICES");
        return info;
    }

    public async Task<DeviceCatalog> DiscoverAsync(CancellationToken ct)
    {
        var gpuBackends = new[] { "cuda", "vulkan" }.Where(b => FolderFor(b) != null).ToArray();
        // Sequential: probing CUDA and Vulkan at the same moment made the Vulkan probe report no devices on some drivers.
        var queries = new List<DeviceCatalog>();
        foreach (var b in gpuBackends) queries.Add(await QueryAsync(b, ct));
        return new(queries.SelectMany(q => q.Devices).ToArray(), queries.SelectMany(q => q.Errors).ToArray(), InstalledBackends);
    }

    async Task<DeviceCatalog> QueryAsync(string backend, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        ProcessStartInfo info;
        try { (info, _) = await PrepareAsync(backend, ct); }
        catch (Core.SnapTransException ex) when (ex.Code == "EngineTampered") { return new([], [$"{backend}: integrity check failed ({ex.Args[1]})"], []); }
        using var process = new Process { StartInfo = info };
        foreach (var arg in new[] { "--verbosity", "5", "--list-devices" }) process.StartInfo.ArgumentList.Add(arg);
        try {
            process.Start();
            var output = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var errors = process.StandardError.ReadToEndAsync(CancellationToken.None);
            try { await process.WaitForExitAsync(timeout.Token); }
            finally {
                if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(CancellationToken.None); }
            }
            var stdout = await output; var stderr = await errors;
            if (process.ExitCode != 0) return new([], [$"{backend}: exit {process.ExitCode}"], []);
            if (Environment.GetEnvironmentVariable("SNAPTRANS_DEBUG_DEVICES") == "1") Console.Error.WriteLine($"[{backend}] {stdout}");
            return new(Parse(backend, stdout, stderr), [], []);
        } catch (OperationCanceledException) when (!ct.IsCancellationRequested) {
            return new([], [$"{backend}: timeout"], []);
        } catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception or InvalidOperationException) {
            return new([], [$"{backend}: {ex.GetType().Name}"], []);
        }
    }

    public static ComputeDevice[] Parse(string backend, string stdout, string stderr)
    {
        var devices = new List<ComputeDevice>();
        foreach (Match match in Regex.Matches(stdout, @"^\s*(?<id>CUDA\d+|Vulkan\d+):\s*(?<name>.+) \((?<mem>\d+) MiB, \d+ MiB free\)\s*$", RegexOptions.Multiline)) {
            var id = match.Groups["id"].Value;
            if (!id.StartsWith(backend, StringComparison.OrdinalIgnoreCase)) continue;
            var name = match.Groups["name"].Value.Trim();
            int index = int.Parse(Regex.Match(id, @"\d+$").Value, CultureInfo.InvariantCulture);
            int ordinal = devices.Count(x => x.Name == name);
            var key = $"{backend}:{Uri.EscapeDataString(name)}:{ordinal}";
            bool integrated = backend == "vulkan" && Regex.IsMatch(stderr, $@"ggml_vulkan: {index} = [^\r\n]+\| uma: 1 \|");
            devices.Add(new(key, backend, name, index, integrated, long.Parse(match.Groups["mem"].Value, CultureInfo.InvariantCulture), ordinal));
        }
        return devices.ToArray();
    }
}
