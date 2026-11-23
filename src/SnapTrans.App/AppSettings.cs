using System.Text.Json;
using SnapTrans.App.Native;

namespace SnapTrans.App;

/// <summary>%LOCALAPPDATA%\MyPLaMo-SnapTrans\settings.json (or SNAPTRANS_PROFILE). Not shared with MyPLaMo.</summary>
public sealed class AppSettings
{
    public static readonly string Home = Environment.GetEnvironmentVariable("SNAPTRANS_PROFILE") is { Length: > 0 } p
        ? p : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MyPLaMo-SnapTrans");
    static string FilePath => Path.Combine(Home, "settings.json");
    public static string EngineRoot => Path.Combine(Home, "engine");
    public static string TessdataFolder => Path.Combine(Home, "tessdata");

    public string ModelFolder { get; set; } = Path.Combine(Home, "models");
    public string ModelId { get; set; } = "";
    public bool LicenseAccepted { get; set; }
    /// <summary>"auto", "cpu" or a ComputeDevice.Key.</summary>
    public string Device { get; set; } = "auto";
    public string DeviceLabel { get; set; } = "";
    public SnapModifiers Modifiers { get; set; } = SnapModifiers.Ctrl | SnapModifiers.Alt;
    /// <summary>"auto" (Japanese ⇄ English) or a TranslationLanguage id.</summary>
    public string Target { get; set; } = "auto";
    /// <summary>"windows" or "tesseract".</summary>
    public string OcrEngine { get; set; } = "windows";
    /// <summary>"" = automatic, or a recognizer language tag.</summary>
    public string OcrLanguage { get; set; } = "";
    /// <summary>"auto", "ja-JP" or "en-US".</summary>
    public string Language { get; set; } = "auto";
    /// <summary>"system", "light" or "dark".</summary>
    public string Theme { get; set; } = "system";
    public bool Enabled { get; set; } = true;

    public static AppSettings Load()
    {
        try { if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        return new();
    }

    public void Save()
    {
        Directory.CreateDirectory(Home);
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(FilePath + ".tmp", FilePath, true);
    }
}
