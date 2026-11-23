using System.Security.Cryptography;
using System.Text.Json;
using SnapTrans.Core;

namespace SnapTrans.Llama;

/// <summary>
/// Verifies an engine folder (llama-server.exe and every DLL) against the SHA-256 manifest of the pinned llama.cpp
/// release before anything in it is started. The folder must contain exactly the manifest's executables: an extra DLL
/// could be picked up by the loader (ggml loads backends by name). Verified files stay open for the rest of the session
/// with a share mode that denies writing and deleting, so they cannot be swapped after the check.
/// </summary>
public static class EngineIntegrity
{
    static readonly Dictionary<string, Dictionary<string, string>> Manifest = LoadManifest();
    static readonly Dictionary<string, List<FileStream>> Pinned = new(StringComparer.OrdinalIgnoreCase);
    static readonly SemaphoreSlim Gate = new(1, 1);

    static Dictionary<string, Dictionary<string, string>> LoadManifest()
    {
        using var stream = typeof(EngineIntegrity).Assembly.GetManifestResourceStream("SnapTrans.Llama.engine-manifest.json")!;
        using var doc = JsonDocument.Parse(stream);
        var result = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var backend in doc.RootElement.EnumerateObject().Where(p => p.Value.ValueKind == JsonValueKind.Object))
            result[backend.Name] = backend.Value.EnumerateObject().ToDictionary(f => f.Name, f => f.Value.GetString()!, StringComparer.OrdinalIgnoreCase);
        return result;
    }

    public static IReadOnlyDictionary<string, string> FilesFor(string backend) => Manifest[backend];

    static bool IsExecutable(string name) => name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);

    /// <summary>Verifies (once per session) and pins the folder. Throws <see cref="SnapTransException"/> "EngineTampered".</summary>
    public static async Task EnsureVerifiedAsync(string folder, string backend, CancellationToken ct)
    {
        folder = Path.GetFullPath(folder);
        await Gate.WaitAsync(ct);
        try {
            if (Pinned.ContainsKey(folder)) return;
            var expected = Manifest[backend];
            var present = Directory.EnumerateFiles(folder).Select(Path.GetFileName).Where(n => n != null && IsExecutable(n!)).ToList();
            var extra = present.Where(n => !expected.ContainsKey(n!) && !MicrosoftSignature.IsVcRuntime(n!)).ToList();
            if (extra.Count > 0) throw new SnapTransException("EngineTampered", backend, "unexpected file");
            var streams = new List<FileStream>();
            try {
                // Visual C++ runtime shipped next to the engine (optional): Microsoft-signed, any version.
                foreach (var name in present.Where(n => MicrosoftSignature.IsVcRuntime(n!))) {
                    var path = Path.Combine(folder, name!);
                    streams.Add(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read));
                    if (!MicrosoftSignature.IsValidMicrosoftFile(path)) throw new SnapTransException("EngineTampered", backend, "invalid signature");
                }
                foreach (var (name, sha) in expected) {
                    var path = Path.Combine(folder, name);
                    if (!File.Exists(path)) throw new SnapTransException("EngineTampered", backend, "missing file");
                    // Read + execute stay possible for llama-server; writers and deleters are refused while we hold this.
                    var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, FileOptions.Asynchronous | FileOptions.SequentialScan);
                    streams.Add(fs);
                    var hash = Convert.ToHexString(await SHA256.HashDataAsync(fs, ct)).ToLowerInvariant();
                    if (hash != sha) throw new SnapTransException("EngineTampered", backend, "hash mismatch");
                }
            } catch {
                foreach (var s in streams) s.Dispose();
                throw;
            }
            Pinned[folder] = streams;
        } finally { Gate.Release(); }
    }

    /// <summary>Verifies a freshly extracted folder (e.g. the CUDA staging folder) without pinning it.</summary>
    public static async Task VerifyOnceAsync(string folder, string backend, CancellationToken ct)
    {
        var expected = Manifest[backend];
        var present = Directory.EnumerateFiles(folder).Select(Path.GetFileName).Where(n => n != null && IsExecutable(n!)).ToList();
        if (present.Any(n => !expected.ContainsKey(n!) && !MicrosoftSignature.IsVcRuntime(n!))) throw new SnapTransException("EngineTampered", backend, "unexpected file");
        foreach (var name in present.Where(n => MicrosoftSignature.IsVcRuntime(n!)))
            if (!MicrosoftSignature.IsValidMicrosoftFile(Path.Combine(folder, name!))) throw new SnapTransException("EngineTampered", backend, "invalid signature");
        foreach (var (name, sha) in expected) {
            var path = Path.Combine(folder, name);
            if (!File.Exists(path)) throw new SnapTransException("EngineTampered", backend, "missing file");
            await using var fs = File.OpenRead(path);
            if (Convert.ToHexString(await SHA256.HashDataAsync(fs, ct)).ToLowerInvariant() != sha) throw new SnapTransException("EngineTampered", backend, "hash mismatch");
        }
    }

    /// <summary>Releases the pins on a folder (before the user removes it, e.g. uninstalling the CUDA engine).</summary>
    public static void Release(string folder)
    {
        Gate.Wait();
        try {
            if (Pinned.Remove(Path.GetFullPath(folder), out var streams)) foreach (var s in streams) s.Dispose();
        } finally { Gate.Release(); }
    }
}
