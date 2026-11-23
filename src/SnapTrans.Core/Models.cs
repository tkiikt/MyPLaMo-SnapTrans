using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SnapTrans.Core;

/// <summary>One file PFN published on Hugging Face for a model (the GGUF changes when the embedded chat template is updated).</summary>
public sealed record ModelVersion(
    [property: JsonPropertyName("rev")] string Revision,
    [property: JsonPropertyName("date")] string Date,
    [property: JsonPropertyName("bytes")] long Bytes,
    [property: JsonPropertyName("sha")] string Sha256);

/// <summary>
/// Official PLaMo 3 Translate GGUF (Q4_K_M) published by PFN on Hugging Face. Downloads are pinned to the current
/// revision; <see cref="Versions"/> lists every official file (all revisions, from the Hub's LFS metadata), so a
/// genuine older download, e.g. one made by MyPLaMo before a template update, is recognised instead of reported as corrupt.
/// </summary>
public sealed record ModelInfo(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("file")] string File,
    [property: JsonPropertyName("bytes")] long Bytes,
    [property: JsonPropertyName("sha")] string Sha256,
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("versions")] ModelVersion[] Versions)
{
    public static IReadOnlyList<ModelInfo> Catalog { get; } = JsonSerializer.Deserialize<ModelInfo[]>(
        typeof(ModelInfo).Assembly.GetManifestResourceStream("SnapTrans.Core.catalog.json")!)!;

    public static ModelInfo? Find(string id) => Catalog.FirstOrDefault(m => m.Id == id);

    public string DisplayName => $"plamo-3-translate-{Id}";
    public string RepositoryUrl => $"https://huggingface.co/pfnet/plamo-3-translate-{Id}-GGUF";

    public ModelVersion? VersionFor(string sha256) => Versions.FirstOrDefault(v => v.Sha256.Equals(sha256, StringComparison.OrdinalIgnoreCase));
    public bool IsCurrent(string sha256) => sha256.Equals(Sha256, StringComparison.OrdinalIgnoreCase);
    public bool IsKnownSize(long bytes) => bytes == Bytes || Versions.Any(v => v.Bytes == bytes);
}

/// <summary>
/// Ready = the current official file (size + SHA-256 verified for this exact file).
/// Outdated = an older official file (verified): usable, an update is recommended.
/// Unverified = present with an official size but not hashed yet (first time seen, or the file changed).
/// Corrupt = a size or SHA-256 that matches no official file.
/// </summary>
public enum ModelState { Missing, Partial, Unverified, Corrupt, Ready, Outdated }

public enum DownloadPhase { Connecting, Downloading, Verifying, Done }

public sealed record DownloadProgress(DownloadPhase Phase, long Received, long Total, double BytesPerSecond)
{
    public double Fraction => Total <= 0 ? 0 : (double)Received / Total;
}

/// <summary>
/// SHA-256 results keyed by full path + size + modification time, kept in the app's own profile
/// (never next to the model, so a folder owned by another app is not written to just by reading it).
/// </summary>
public static class VerificationCache
{
    sealed record Entry(string Stamp, string Sha256);
    static readonly object Sync = new();
    static Dictionary<string, Entry>? entries;
    /// <summary>JSON file for persistence; null keeps results in memory only (e.g. tools).</summary>
    public static string? FilePath { get; set; }

    public static string Stamp(FileInfo f) => $"{f.Length}|{f.LastWriteTimeUtc.Ticks}";

    static Dictionary<string, Entry> Entries()
    {
        if (entries != null) return entries;
        entries = new(StringComparer.OrdinalIgnoreCase);
        try {
            if (FilePath != null && System.IO.File.Exists(FilePath))
                entries = JsonSerializer.Deserialize<Dictionary<string, Entry>>(System.IO.File.ReadAllText(FilePath)) is { } loaded
                    ? new(loaded, StringComparer.OrdinalIgnoreCase) : entries;
        } catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        return entries;
    }

    // Results from this session only. Used instead of the persisted cache where others could swap the file while
    // keeping its size and timestamp.
    static readonly Dictionary<string, Entry> Session = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The recorded hash if the file is unchanged since it was hashed, else null. For files that users other than the
    /// current one can write (see <see cref="FolderTrust"/>), only hashes computed in this session count.
    /// </summary>
    public static string? Lookup(FileInfo file)
    {
        bool persistedOk = !FolderTrust.IsWritableByOthers(file.FullName);
        lock (Sync) {
            if (Session.TryGetValue(file.FullName, out var s) && s.Stamp == Stamp(file)) return s.Sha256;
            return persistedOk && Entries().TryGetValue(file.FullName, out var e) && e.Stamp == Stamp(file) ? e.Sha256 : null;
        }
    }

    public static void Record(FileInfo file, string sha256)
    {
        lock (Sync) {
            file.Refresh();
            Entries()[file.FullName] = new(Stamp(file), sha256.ToLowerInvariant());
            Session[file.FullName] = new(Stamp(file), sha256.ToLowerInvariant());
            if (FilePath == null) return;
            try {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                System.IO.File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(entries));
                System.IO.File.Move(FilePath + ".tmp", FilePath, true);
            } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    public static void Forget(string path) { lock (Sync) { Entries().Remove(Path.GetFullPath(path)); Session.Remove(Path.GetFullPath(path)); } }
}

/// <summary>
/// Models in a user-chosen folder. Reading (state, SHA-256 verification) never writes to the folder; only the explicit
/// user actions Download and Delete do.
/// </summary>
public sealed class ModelStore(string folder)
{
    public string Folder { get; } = folder;

    public static HttpMessageHandler? HandlerOverride { get; set; }

    public string PathOf(ModelInfo m) => Path.Combine(Folder, m.File);
    string PartOf(ModelInfo m) => PathOf(m) + ".part";
    /// <summary>Marker files written next to models by SnapTrans before 0.1.1; only removed when the user deletes that model.</summary>
    string LegacyMarker(ModelInfo m) => PathOf(m) + ".verified";

    public ModelState StateOf(ModelInfo m)
    {
        var file = new FileInfo(PathOf(m));
        if (!file.Exists) return File.Exists(PartOf(m)) ? ModelState.Partial : ModelState.Missing;
        if (!m.IsKnownSize(file.Length)) return ModelState.Corrupt;
        return VerificationCache.Lookup(file) switch {
            null => ModelState.Unverified,
            var sha when m.IsCurrent(sha) => ModelState.Ready,
            var sha when m.VersionFor(sha) != null => ModelState.Outdated,
            _ => ModelState.Corrupt
        };
    }

    /// <summary>The official version the file was verified as (null if unverified or not official).</summary>
    public ModelVersion? VersionOf(ModelInfo m)
    {
        var file = new FileInfo(PathOf(m));
        return file.Exists && VerificationCache.Lookup(file) is { } sha ? m.VersionFor(sha) : null;
    }

    public long PartialBytes(ModelInfo m) => File.Exists(PartOf(m)) ? new FileInfo(PartOf(m)).Length : 0;

    /// <summary>
    /// Downloads the current official file. With <paramref name="replaceExisting"/>, an existing (older) file is replaced
    /// only after the new one has been fully downloaded and verified.
    /// </summary>
    public async Task DownloadAsync(ModelInfo m, IProgress<DownloadProgress>? progress, CancellationToken ct, bool replaceExisting = false)
    {
        if (!Path.IsPathFullyQualified(Folder)) throw new SnapTransException("FolderNotAbsolute");
        Directory.CreateDirectory(Folder);
        var dest = PathOf(m);
        if (File.Exists(dest) && !replaceExisting) { await VerifyAsync(m, progress, ct); return; }
        var part = PartOf(m);
        await using (var output = new FileStream(part, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1 << 17, true)) {
            if (output.Length > m.Bytes) output.SetLength(0);
            long offset = output.Length;
            var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Folder))!);
            if (drive.AvailableFreeSpace < m.Bytes - offset) throw new SnapTransException("DiskFull", m.Bytes - offset);
            if (offset < m.Bytes) {
                progress?.Report(new(DownloadPhase.Connecting, offset, m.Bytes, 0));
                using var client = HandlerOverride is { } h ? new HttpClient(h, false) : new HttpClient();
                client.Timeout = Timeout.InfiniteTimeSpan;
                client.DefaultRequestHeaders.UserAgent.ParseAdd("MyPLaMo-SnapTrans/0.1");
                using var request = new HttpRequestMessage(HttpMethod.Get, m.Url);
                if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                if (!response.IsSuccessStatusCode) throw new SnapTransException("HttpError", (int)response.StatusCode);
                if (response.StatusCode == HttpStatusCode.PartialContent) {
                    if (response.Content.Headers.ContentRange?.From != offset) throw new SnapTransException("ResumeMismatch");
                } else { output.SetLength(0); offset = 0; }
                output.Position = offset;
                await using var input = await response.Content.ReadAsStreamAsync(ct);
                var buffer = new byte[1 << 17];
                var timer = Stopwatch.StartNew();
                long lastReport = -1000; int n;
                while ((n = await input.ReadAsync(buffer, ct)) > 0) {
                    if (output.Position + n > m.Bytes) throw new SnapTransException("SizeMismatch");
                    await output.WriteAsync(buffer.AsMemory(0, n), ct);
                    if (timer.ElapsedMilliseconds - lastReport < 200) continue;
                    lastReport = timer.ElapsedMilliseconds;
                    progress?.Report(new(DownloadPhase.Downloading, output.Position, m.Bytes, (output.Position - offset) / Math.Max(0.01, timer.Elapsed.TotalSeconds)));
                }
                if (output.Length != m.Bytes) throw new SnapTransException("Interrupted");
            }
        }
        progress?.Report(new(DownloadPhase.Verifying, m.Bytes, m.Bytes, 0));
        var downloaded = await HashAsync(part, ct);
        if (!m.IsCurrent(downloaded)) {
            File.Delete(part);
            throw new SnapTransException("HashMismatch");
        }
        File.Move(part, dest, overwrite: replaceExisting);
        VerificationCache.Record(new FileInfo(dest), downloaded);
        progress?.Report(new(DownloadPhase.Done, m.Bytes, m.Bytes, 0));
    }

    /// <summary>
    /// Verifies an existing file (read-only): size first, then SHA-256 once per file version; the result is cached in the
    /// app profile, so later starts are instant and a changed or replaced file is hashed again.
    /// Throws for a file that matches no official version.
    /// </summary>
    public async Task<ModelVersion> VerifyAsync(ModelInfo m, IProgress<DownloadProgress>? progress, CancellationToken ct, bool force = false)
    {
        var file = new FileInfo(PathOf(m));
        if (!file.Exists) throw new SnapTransException("ModelMissing");
        if (!m.IsKnownSize(file.Length)) throw new SnapTransException("ExistingHashMismatch");
        var sha = force ? null : VerificationCache.Lookup(file);
        if (sha == null) {
            progress?.Report(new(DownloadPhase.Verifying, 0, file.Length, 0));
            sha = (await HashAsync(file.FullName, ct)).ToLowerInvariant();
            VerificationCache.Record(file, sha);
            progress?.Report(new(DownloadPhase.Done, file.Length, file.Length, 0));
        }
        return m.VersionFor(sha) ?? throw new SnapTransException("ExistingHashMismatch");
    }

    /// <summary>User action (confirmed in the UI): removes the model, a partial download and SnapTrans' own legacy marker.</summary>
    public void Delete(ModelInfo m)
    {
        foreach (var p in new[] { PathOf(m), PartOf(m), LegacyMarker(m) })
            if (File.Exists(p)) File.Delete(p);
        VerificationCache.Forget(PathOf(m));
    }

    /// <summary>
    /// Check run by the engine right before it loads the model, on a handle that denies writers and stays open while
    /// the model is in use. In a folder only the current user (or an administrator) can write, an unchanged file with a
    /// cached official hash is accepted as is; anywhere else the file is hashed again through this handle.
    /// </summary>
    public static async Task GuardAsync(ModelInfo m, FileStream model, CancellationToken ct)
    {
        var file = new FileInfo(model.Name);
        if (!FolderTrust.IsWritableByOthers(file.FullName) && VerificationCache.Lookup(file) is { } cached && m.VersionFor(cached) != null) return;
        model.Position = 0;
        var sha = Convert.ToHexString(await SHA256.HashDataAsync(model, ct)).ToLowerInvariant();
        model.Position = 0;
        if (m.VersionFor(sha) == null) throw new SnapTransException("ExistingHashMismatch");
        VerificationCache.Record(file, sha);
    }

    static async Task<string> HashAsync(string path, CancellationToken ct)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, true);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream, ct)).ToLowerInvariant();
    }
}
