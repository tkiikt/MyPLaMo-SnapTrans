using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using SnapTrans.Core;

namespace SnapTrans.Llama;

/// <summary>
/// Optional CUDA engine: downloaded by the user from the official llama.cpp GitHub release
/// (same tag as the bundled engine), verified by SHA-256 and extracted into a per-user folder.
/// </summary>
public static class CudaEngineInstaller
{
    public const string Tag = "b12121";
    static readonly (string Name, string Sha256, long Bytes)[] Assets = [
        ($"llama-{Tag}-bin-win-cuda-13.4-x64.zip", "7b5676ad9fa4ecd3de2605e3f48edbdcd44dad6c45c8e2656eeebe8725007479", 0),
        ("cudart-llama-bin-win-cuda-13.4-x64.zip", "738f8c251ac22b70c3ae6f83a10cf222725df0395246a2cf58f32bdb85fbe668", 0),
    ];
    static readonly Regex Keep = new(@"^(ggml(?:-base|-cpu-[^.]+|-cuda)?|libomp|llama|llama-common|llama-server-impl|mtmd|cudart64_[^.]+|cublas64_[^.]+|cublasLt64_[^.]+)\.dll$|^llama-server\.exe$|^LICENSE", RegexOptions.IgnoreCase);

    public static string ReleaseUrl => $"https://github.com/ggml-org/llama.cpp/releases/tag/{Tag}";

    /// <param name="root">Engine root; files go to root/cuda.</param>
    public static async Task InstallAsync(string root, string? llamaLicense, string? vcRuntimeSource, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        var downloads = Path.Combine(root, "downloads");
        Directory.CreateDirectory(downloads);
        using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MyPLaMo-SnapTrans/0.1");
        foreach (var (name, sha, _) in Assets) {
            var archive = Path.Combine(downloads, name);
            if (File.Exists(archive) && await HashAsync(archive, ct) == sha) continue;
            var url = $"https://github.com/ggml-org/llama.cpp/releases/download/{Tag}/{name}";
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!response.IsSuccessStatusCode) throw new SnapTransException("HttpError", (int)response.StatusCode);
            long total = response.Content.Headers.ContentLength ?? 0, received = 0;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            await using (var input = await response.Content.ReadAsStreamAsync(ct))
            await using (var output = File.Create(archive + ".part")) {
                var buffer = new byte[1 << 17]; int n; long last = -1000;
                while ((n = await input.ReadAsync(buffer, ct)) > 0) {
                    await output.WriteAsync(buffer.AsMemory(0, n), ct); received += n;
                    if (sw.ElapsedMilliseconds - last < 200) continue;
                    last = sw.ElapsedMilliseconds;
                    progress?.Report(new(DownloadPhase.Downloading, received, total, received / Math.Max(0.01, sw.Elapsed.TotalSeconds)));
                }
            }
            progress?.Report(new(DownloadPhase.Verifying, received, total, 0));
            if (await HashAsync(archive + ".part", ct) != sha) { File.Delete(archive + ".part"); throw new SnapTransException("HashMismatch"); }
            File.Move(archive + ".part", archive, true);
        }
        var staging = Path.Combine(root, "cuda.staging");
        if (Directory.Exists(staging)) Directory.Delete(staging, true);
        Directory.CreateDirectory(staging);
        foreach (var (name, _, _) in Assets) {
            using var zip = ZipFile.OpenRead(Path.Combine(downloads, name));
            foreach (var entry in zip.Entries.Where(e => e.Name.Length > 0 && Keep.IsMatch(e.Name)))
                entry.ExtractToFile(Path.Combine(staging, entry.Name), true);
        }
        if (!File.Exists(Path.Combine(staging, "llama-server.exe"))) throw new SnapTransException("EngineMissing", "cuda");
        // The CUDA build needs the same Visual C++ runtime as the bundled engines: reuse the copy shipped in engineulkan.
        if (vcRuntimeSource != null)
            foreach (var name in MicrosoftSignature.VcRuntimeFiles) {
                var source = Path.Combine(vcRuntimeSource, name);
                if (File.Exists(source)) File.Copy(source, Path.Combine(staging, name), true);
            }
        // Every executable must match the release manifest (same check as before each start).
        await EngineIntegrity.VerifyOnceAsync(staging, "cuda", ct);
        // The release zips carry no llama.cpp LICENSE; ship the same MIT text as the bundled engine.
        if (llamaLicense != null && File.Exists(llamaLicense)) File.Copy(llamaLicense, Path.Combine(staging, "LICENSE-llama.cpp"), true);
        var target = Path.Combine(root, "cuda");
        if (Directory.Exists(target)) Directory.Delete(target, true);
        Directory.Move(staging, target);
        Directory.Delete(downloads, true);
        progress?.Report(new(DownloadPhase.Done, 1, 1, 0));
    }

    public static void Uninstall(string root)
    {
        EngineIntegrity.Release(Path.Combine(root, "cuda"));
        var target = Path.Combine(root, "cuda");
        if (Directory.Exists(target)) Directory.Delete(target, true);
    }

    static async Task<string> HashAsync(string path, CancellationToken ct)
    {
        await using var s = File.OpenRead(path);
        return Convert.ToHexString(await SHA256.HashDataAsync(s, ct)).ToLowerInvariant();
    }
}
