using System.Globalization;
using SnapTrans.Core;

namespace SnapTrans.App;

/// <summary>
/// UI strings (日本語 / English). "auto" follows the Windows display language (Japanese → 日本語, otherwise English).
/// Switching applies immediately, like TrayIconCleaner.
/// </summary>
public static class Loc
{
    public static string Current { get; private set; } = "ja-JP";
    public static bool Japanese => Current == "ja-JP";
    public static event Action? Changed;

    public static string Resolve(string setting) => setting switch {
        "ja-JP" or "en-US" => setting,
        _ => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ja" || CultureInfo.InstalledUICulture.TwoLetterISOLanguageName == "ja" ? "ja-JP" : "en-US"
    };

    public static void Set(string setting)
    {
        var resolved = Resolve(setting);
        if (resolved == Current) return;
        Current = resolved;
        Changed?.Invoke();
    }

    public static void Init(string setting) => Current = Resolve(setting);

    /// <summary>PLaMo Community License (PFN): Japanese page for the Japanese UI, English page otherwise.</summary>
    public static string LicenseUrl => Japanese
        ? "https://plamo.preferredai.jp/info/plamo-community-license-ja"
        : "https://plamo.preferredai.jp/info/plamo-community-license-en";

    public static string T(string key) => Table.TryGetValue(key, out var v) ? (Japanese ? v.Ja : v.En) : key;
    public static string F(string key, params object?[] args) => string.Format(CultureInfo.CurrentCulture, T(key), args);

    public static string Error(Exception ex) => ex switch {
        SnapTransException se when Table.ContainsKey("Err_" + se.Code) => F("Err_" + se.Code, se.Args),
        SnapTransException se => se.Code + (se.Args.Length > 0 ? " " + string.Join(" ", se.Args) : ""),
        HttpRequestException => T("Err_Network"),
        OperationCanceledException => T("Canceled"),
        _ => ex.Message
    };

    public static string Size(long bytes) => bytes >= 1_000_000_000 ? $"{bytes / 1e9:0.00} GB" : $"{bytes / 1e6:0} MB";

    static readonly Dictionary<string, (string Ja, string En)> Table = new() {
        ["AppName"] = ("MyPLaMo SnapTrans", "MyPLaMo SnapTrans"),
        ["Popup_Title"] = ("MyPLaMo SnapTrans · 翻訳", "MyPLaMo SnapTrans · Translation"),
        ["Popup_TitleSource"] = ("MyPLaMo SnapTrans · 原文", "MyPLaMo SnapTrans · Original"),
        ["Popup_Copy"] = ("コピー", "Copy"),
        ["Popup_Copied"] = ("コピーしました", "Copied"),
        ["Popup_Close"] = ("閉じる (Esc)", "Close (Esc)"),
        ["Popup_ShowSource"] = ("原文を表示", "Show original"),
        ["Popup_ShowTranslation"] = ("訳文を表示", "Show translation"),
        ["Popup_Settings"] = ("設定", "Settings"),
        ["Stage_Recognizing"] = ("文字を読み取り中…", "Reading text…"),
        ["Stage_Loading"] = ("モデルを読み込み中（{0}）…", "Loading model ({0})…"),
        ["Stage_Translating"] = ("翻訳中…", "Translating…"),
        ["Stage_Done"] = ("{0} · {1} · {2:0.00} 秒", "{0} · {1} · {2:0.00} s"),
        ["NoText"] = ("文字を読み取れませんでした。範囲を広げるか、OCR の言語を確認してください。", "No text was recognized. Try a larger area or check the OCR language."),
        ["Canceled"] = ("キャンセルしました。", "Canceled."),
        ["Stage_Switching"] = ("翻訳エンジンを切り替えています…", "Switching the translation engine…"),
        ["Hook_Failed"] = ("ドラッグ翻訳を開始できませんでした（入力フックを設定できません）。設定画面を確認してください。", "Drag-to-translate could not start (input hooks could not be installed). See Settings."),
        ["Hook_OtherInstance"] = ("別の SnapTrans がドラッグ翻訳を使っているため、こちらではドラッグ翻訳を無効にしました（設定は変更できます）。", "Another SnapTrans is already handling drag-to-translate, so it is disabled in this one (settings still work)."),
        ["Hook_FailedDetail"] = ("入力フックを設定できなかったため、ドラッグ翻訳は動作していません。アプリを再起動してください。詳細: {0}", "Input hooks could not be installed, so drag-to-translate is not working. Please restart the app. Details: {0}"),
        ["Balloon_Corrupt"] = ("選択中のモデルファイルが公式ファイルと一致しません（破損の可能性）。設定画面で削除して再取得してください。", "The selected model file does not match the official file (possibly corrupt). Delete and download it again in Settings."),
        ["Engine_Changing"] = ("切り替えています… 実行中の読み込み・翻訳を止めて、終わるのを待っています。", "Switching… stopping the running load/translation and waiting for it to finish."),
        ["Fallback"] = ("GPU を使えなかったため CPU で実行しています（{0}）", "Running on CPU because the GPU could not be used ({0})"),

        ["Tray_Tip"] = ("MyPLaMo SnapTrans — {0} を押しながらドラッグ", "MyPLaMo SnapTrans — hold {0} and drag"),
        ["Tray_Settings"] = ("設定を開く", "Open settings"),
        ["Tray_Last"] = ("最後の翻訳を表示", "Show last translation"),
        ["Tray_Enabled"] = ("ドラッグ翻訳を有効にする", "Enable drag-to-translate"),
        ["Tray_Exit"] = ("終了", "Exit"),
        ["Balloon_NoModel"] = ("設定画面で翻訳モデルをダウンロードしてください。", "Download a translation model in Settings."),
        ["Balloon_Ready"] = ("{0} を押しながら画面をドラッグすると翻訳します。", "Hold {0} and drag on the screen to translate."),
        ["AlreadyRunning"] = ("MyPLaMo SnapTrans は起動中です。通知領域のアイコンから設定を開けます。", "MyPLaMo SnapTrans is already running. Open Settings from the notification area icon."),

        ["Settings_Title"] = ("MyPLaMo SnapTrans 設定", "MyPLaMo SnapTrans Settings"),
        ["Settings_Subtitle"] = ("画面をドラッグで囲んで、ローカルの PLaMo 3 Translate で翻訳します。", "Drag around any text on screen and translate it locally with PLaMo 3 Translate."),
        ["BuiltWithPlamo"] = ("Built with PLaMo", "Built with PLaMo"),

        ["Sec_Model"] = ("翻訳モデル", "Translation model"),
        ["Model_Desc"] = ("PFN 公式の GGUF（Q4_K_M）を Hugging Face から直接ダウンロードします。まずは 0.8B（軽量）か 2B（高品質）がおすすめです。", "Downloads PFN's official GGUF (Q4_K_M) directly from Hugging Face. 0.8B (light) or 2B (better quality) is recommended."),
        ["Model_Missing"] = ("未取得", "Not downloaded"),
        ["Model_Partial"] = ("一部取得済み（{0}）・再開できます", "Partially downloaded ({0}) · can resume"),
        ["Model_Ready"] = ("取得済み", "Downloaded"),
        ["Model_InUse"] = ("使用中", "In use"),
        ["Model_Unverified"] = ("取得済み・未検証（SHA-256 を確認します）", "Downloaded · not verified yet (SHA-256 check pending)"),
        ["Model_VerifyingExisting"] = ("SHA-256 を確認しています…", "Checking SHA-256…"),
        ["Model_Corrupt"] = ("ファイルが壊れています（サイズまたは SHA-256 が公式ファイルと不一致）。再ダウンロードしてください。", "The file is corrupt (size or SHA-256 differs from the official file). Please download it again."),
        ["Model_Redownload"] = ("再ダウンロード", "Download again"),
        ["Model_Download"] = ("ダウンロード", "Download"),
        ["Model_Resume"] = ("再開", "Resume"),
        ["Model_Use"] = ("使用する", "Use"),
        ["Model_Delete"] = ("削除", "Delete"),
        ["Model_Cancel"] = ("中断", "Pause"),
        ["Model_Large"] = ("大きいモデル（メモリに余裕がある PC 向け）", "Large model (for PCs with plenty of memory)"),
        ["Model_Progress"] = ("{0}　{1:0.0}%　{2} / {3}　{4:0.0} MB/s", "{0}　{1:0.0}%　{2} / {3}　{4:0.0} MB/s"),
        ["Model_Verifying"] = ("SHA-256 を検証しています…", "Verifying SHA-256…"),
        ["Model_Connecting"] = ("接続しています…", "Connecting…"),
        ["Model_Downloaded"] = ("{0} をダウンロードして検証しました。", "{0} was downloaded and verified."),
        ["Model_Paused"] = ("中断しました。「再開」で続きから取得します。", "Paused. Press Resume to continue."),
        ["Model_Deleted"] = ("{0} を削除しました。", "{0} was deleted."),
        ["Model_DeleteConfirm"] = ("{0} を削除しますか？", "Delete {0}?"),
        ["Model_Selected"] = ("{0} を使用します。", "Using {0}."),
        ["Folder"] = ("保存先", "Folder"),
        ["Folder_Change"] = ("変更…", "Change…"),
        ["Folder_Open"] = ("開く", "Open"),
        ["Folder_Pick"] = ("モデルの保存先を選択", "Choose the model folder"),
        ["Folder_Note"] = ("保存先を変えると、そのフォルダーにある取得済みモデルを使います（ファイルは移動しません）。", "Changing the folder uses models already in it (files are not moved)."),
        ["License_Link"] = ("PLaMo コミュニティライセンスを読む", "Read the PLaMo Community License"),
        ["License_Agree"] = ("ライセンスを確認し、同意します（ダウンロードに必要です）", "I have read and agree to the license (required to download)"),
        ["License_Required"] = ("ダウンロードの前にライセンスへの同意が必要です。", "Please agree to the license before downloading."),

        ["Sec_Device"] = ("実行デバイス", "Compute device"),
        ["Device_Desc"] = ("自動では CUDA → Vulkan → CPU の順に使えるものを選びます。GPU で読み込めない場合は CPU に切り替えて理由を表示します。", "Automatic tries CUDA → Vulkan → CPU. If the GPU cannot load the model, SnapTrans switches to CPU and shows why."),
        ["Device_Auto"] = ("自動（GPU 優先）", "Automatic (GPU first)"),
        ["Device_Cpu"] = ("CPU のみ", "CPU only"),
        ["Device_Refresh"] = ("GPU 一覧を更新", "Refresh GPUs"),
        ["Device_Scanning"] = ("GPU を確認しています…", "Detecting GPUs…"),
        ["Device_Found"] = ("検出: {0}", "Detected: {0}"),
        ["Device_None"] = ("GPU は検出されませんでした。", "No GPU was detected."),
        ["Device_Current"] = ("現在: {0}", "Current: {0}"),
        ["Device_NotLoaded"] = ("現在: 未読み込み（最初の翻訳時に読み込みます）", "Current: not loaded (loads on first translation)"),
        ["Cuda_Title"] = ("CUDA エンジン（NVIDIA GPU 用・任意）", "CUDA engine (NVIDIA GPUs, optional)"),
        ["Cuda_Desc"] = ("llama.cpp 公式リリースから CUDA 版（約 600 MB）を取得します。未導入でも Vulkan で GPU を使えます。", "Downloads the CUDA build (~600 MB) from the official llama.cpp release. Without it, GPUs still work through Vulkan."),
        ["Cuda_Install"] = ("CUDA エンジンを導入", "Install CUDA engine"),
        ["Cuda_Remove"] = ("CUDA エンジンを削除", "Remove CUDA engine"),
        ["Cuda_Installed"] = ("導入済み", "Installed"),
        ["Cuda_NotInstalled"] = ("未導入", "Not installed"),

        ["Sec_Shortcut"] = ("ショートカット", "Shortcut"),
        ["Shortcut_Desc"] = ("選んだキーを押しながら画面のどこでも左ドラッグすると、その範囲を翻訳します。ドラッグ中は Esc でキャンセル。", "Hold the selected keys and left-drag anywhere on screen to translate that area. Press Esc while dragging to cancel."),
        ["Shortcut_Need"] = ("キーを 1 つ以上選んでください。", "Select at least one key."),

        ["Sec_Translation"] = ("翻訳", "Translation"),
        ["Target"] = ("訳先の言語", "Translate into"),
        ["Target_Auto"] = ("自動（日本語 ⇄ 英語）", "Automatic (Japanese ⇄ English)"),
        ["Target_Desc"] = ("翻訳元の言語はモデルが自動で判定します。", "The source language is detected by the model."),

        ["Sec_Ocr"] = ("文字認識（OCR）", "Text recognition (OCR)"),
        ["Ocr_Engine"] = ("OCR エンジン", "OCR engine"),
        ["Ocr_Windows"] = ("Windows OCR（標準）", "Windows OCR (default)"),
        ["Ocr_Tesseract"] = ("Tesseract（日本語・英語）", "Tesseract (Japanese, English)"),
        ["Ocr_Language"] = ("OCR の言語", "OCR language"),
        ["Ocr_Auto"] = ("自動", "Automatic"),
        ["Ocr_Installed"] = ("利用可能な OCR 言語: {0}", "Available OCR languages: {0}"),
        ["Ocr_MissingHelp"] = ("{0} の OCR 言語がありません。Windows の［設定］→［時刻と言語］→［言語と地域］で言語を追加し、言語のオプションで「光学式文字認識」を入れてください（SnapTrans は Windows の設定を変更しません）。", "No OCR language for {0}. In Windows Settings → Time & language → Language & region, add the language and install \"Optical character recognition\" in its options (SnapTrans never changes Windows settings)."),
        ["Ocr_Accuracy"] = ("読み取りの精度は、翻訳する文章の言語の OCR が Windows に入っているかで変わります。たとえば英語の画面を訳すなら、Windows の［設定］→［時刻と言語］→［言語と地域］→［言語の追加］で「英語（米国）」を追加し、言語機能のダウンロードが終わるまで待ってください。追加した言語は SnapTrans が自動で使います。", "Recognition is more accurate when Windows has the OCR language of the text you translate. For English pages, add \"English (United States)\" in Windows Settings → Time & language → Language & region → Add a language, and wait until its language features finish downloading. SnapTrans uses added languages automatically."),
        ["Ocr_OpenSettings"] = ("Windows の言語設定を開く", "Open Windows language settings"),
        ["Tess_Missing"] = ("Tesseract の言語データ（eng / jpn, 約 6 MB）がありません。", "Tesseract language data (eng / jpn, ~6 MB) is not installed."),
        ["Tess_Download"] = ("言語データを取得", "Download language data"),
        ["Tess_Ready"] = ("言語データ: {0}", "Language data: {0}"),

        ["Sec_Appearance"] = ("表示", "Appearance"),
        ["UiLanguage"] = ("表示言語", "Display language"),
        ["UiLanguage_Auto"] = ("自動（Windows に合わせる）", "Automatic (match Windows)"),
        ["Theme"] = ("テーマ", "Theme"),
        ["Theme_System"] = ("システム設定に従う", "Use system setting"),
        ["Theme_Light"] = ("ライト", "Light"),
        ["Theme_Dark"] = ("ダーク", "Dark"),

        ["Sec_Startup"] = ("起動", "Startup"),
        ["AutoStart_Label"] = ("サインイン時に起動する（通知領域に常駐）", "Start at sign-in (stay in the notification area)"),
        ["AutoStart_Desc"] = ("オンにすると、Windows にサインインしたときに設定画面を開かずに通知領域で待機します。現在のユーザーのスタートアップ（HKCU の Run）に登録し、管理者権限は不要です。アプリのフォルダーを削除する前にオフにしてください。", "When on, SnapTrans starts in the notification area without opening this window when you sign in to Windows. It is registered for the current user only (HKCU Run) and needs no admin rights. Turn it off before deleting the app folder."),
        ["AutoStart_Relocated"] = ("アプリのフォルダーが移動されていたため、サインイン時の起動先をこの場所に更新しました。", "The app folder had moved, so sign-in startup now points to this location."),
        ["Switch_On"] = ("オン", "On"),
        ["Switch_Off"] = ("オフ", "Off"),
        ["AutoStart_Failed"] = ("サインイン時の起動を変更できませんでした: {0}", "Could not change sign-in startup: {0}"),

        ["Sec_Last"] = ("最後の翻訳", "Last translation"),
        ["Last_None"] = ("まだ翻訳していません。", "Nothing translated yet."),
        ["Last_Source"] = ("原文", "Original"),
        ["Last_Result"] = ("訳文", "Translation"),

        ["Sec_About"] = ("このアプリについて", "About"),
        ["About_Text"] = ("MyPLaMo SnapTrans {0}\n翻訳モデル: PLaMo 3 Translate（Preferred Networks）。モデルは PLaMo コミュニティライセンスに従います。\n推論エンジン: llama.cpp（MIT License）。OCR: Windows.Media.Ocr。", "MyPLaMo SnapTrans {0}\nTranslation model: PLaMo 3 Translate (Preferred Networks), under the PLaMo Community License.\nInference engine: llama.cpp (MIT License). OCR: Windows.Media.Ocr."),
        ["Yes"] = ("はい", "Yes"),
        ["No"] = ("いいえ", "No"),
        ["Cancel"] = ("キャンセル", "Cancel"),
        ["Model_Outdated"] = ("旧版（{0} 公開の公式ファイル）・使用できます。最新版への更新をおすすめします", "Older official file (published {0}) · usable; updating is recommended"),
        ["Model_Huge"] = ("非常に大きいモデル（19.5 GB・GPU メモリ 24 GB 以上推奨）", "Very large model (19.5 GB; 24 GB+ GPU memory recommended)"),
        ["Model_Update"] = ("最新版を取得", "Get latest"),
        ["Confirm_Download_Title"] = ("{0} をダウンロードしますか？", "Download {0}?"),
        ["Confirm_Download_Body"] = ("保存先「{0}」に {1} のファイルを書き込みます。", "{1} will be written to \"{0}\"."),
        ["Confirm_Update_Title"] = ("{0} を最新版に更新しますか？", "Update {0} to the latest version?"),
        ["Confirm_Update_Body"] = ("保存先「{0}」に最新版（{1}）をダウンロードし、検証できたら今のファイルと置き換えます。このフォルダーを他のアプリ（MyPLaMo など）と共有している場合は、そのアプリのファイルも置き換わります。", "The latest file ({1}) is downloaded to \"{0}\" and replaces the current one after verification. If another app (e.g. MyPLaMo) uses this folder, its file is replaced too."),
        ["Confirm_Redownload_Title"] = ("{0} を再ダウンロードしますか？", "Download {0} again?"),
        ["Confirm_Redownload_Body"] = ("壊れているファイルを削除し、保存先「{0}」に {1} をダウンロードします。", "The corrupt file is deleted and {1} is downloaded to \"{0}\"."),
        ["Confirm_Delete_Body"] = ("次のファイルを削除します。他のアプリと共有しているフォルダーの場合は、そのアプリからも使えなくなります。\n{0}", "This file will be deleted. If the folder is shared with another app, that app loses it too.\n{0}"),

        ["Err_Network"] = ("ネットワークに接続できませんでした。", "Could not connect to the network."),
        ["Err_NoModel"] = ("翻訳モデルがありません。設定画面でダウンロードしてください。", "No translation model. Download one in Settings."),
        ["Err_DiskFull"] = ("保存先の空き容量が足りません（あと {0} バイト必要）。", "Not enough free space ({0} more bytes needed)."),
        ["Err_HttpError"] = ("ダウンロードに失敗しました（HTTP {0}）。", "Download failed (HTTP {0})."),
        ["Err_HashMismatch"] = ("SHA-256 が一致しません。ファイルを削除しました。もう一度ダウンロードしてください。", "SHA-256 mismatch. The file was deleted; please download again."),
        ["Err_ExistingHashMismatch"] = ("保存先のファイルが公式ファイルと一致しません。削除して再取得してください。", "The file in the folder does not match the official file. Delete and download again."),
        ["Err_Interrupted"] = ("ダウンロードが途中で止まりました。「再開」で続きから取得します。", "The download stopped. Press Resume to continue."),
        ["Err_ResumeMismatch"] = ("再開位置が一致しません。", "Resume position mismatch."),
        ["Err_SizeMismatch"] = ("配布元のファイルサイズが一致しません。", "The server file size does not match."),
        ["Err_FolderNotAbsolute"] = ("保存先を絶対パスで指定してください。", "Please choose an absolute folder path."),
        ["Err_OcrLanguageMissing"] = ("OCR の言語 {0} を使えません。", "OCR language {0} is not available."),
        ["Err_EngineMissing"] = ("推論エンジン（{0}）が見つかりません。", "Inference engine ({0}) not found."),
        ["Err_EngineExited"] = ("推論エンジンが終了しました（コード {0}）。{1}", "The inference engine exited (code {0}). {1}"),
        ["Err_EngineTimeout"] = ("モデルの読み込みがタイムアウトしました。", "Model loading timed out."),
        ["Err_NotOffloaded"] = ("GPU にモデルを配置できませんでした", "the model could not be placed on the GPU"),
        ["Err_DeviceNotFound"] = ("指定の GPU が見つかりません", "the selected GPU was not found"),
        ["Err_TranslateHttp"] = ("翻訳できませんでした（{0}）。", "Translation failed ({0})."),
        ["Err_TooLong"] = ("文章が長すぎます。範囲を分けてください。", "The text is too long. Select a smaller area."),
        ["Err_EmptyResult"] = ("訳文が空でした。", "The translation was empty."),
        ["Err_ControlTokens"] = ("モデルの制御記号を含む文章は翻訳できません。", "Text containing model control tokens cannot be translated."),
        ["Err_BadLanguage"] = ("翻訳言語が正しくありません。", "Invalid translation language."),
        ["Err_ModelVerifying"] = ("モデルファイルを確認中です（SHA-256）。少し待ってからもう一度お試しください。", "Checking the model file (SHA-256). Please try again in a moment."),
        ["Err_PortInUse"] = ("ローカルのポート {0} を使えませんでした", "local port {0} was unavailable"),
        ["Err_TranslateTimeout"] = ("翻訳が時間内に終わりませんでした。範囲を小さくしてください。", "Translation timed out. Select a smaller area."),
        ["Err_EngineNotLoaded"] = ("翻訳エンジンが起動していません。", "The translation engine is not running."),
        ["Err_EngineTampered"] = ("推論エンジン（{0}）のファイルが公式版と一致しないため起動しませんでした（{1}）。アプリを入れ直してください。", "The inference engine ({0}) does not match the official files and was not started ({1}). Please reinstall the app."),
        ["Err_EngineUnexpectedResponse"] = ("推論エンジンから想定外の応答がありました（{0}）。翻訳を中止しました。", "Unexpected response from the inference engine ({0}). Translation was stopped."),
        ["Err_OcrDataInvalid"] = ("Tesseract の言語データ（{0}）が公式ファイルと一致しません。ファイルを削除して取得し直してください。", "Tesseract language data ({0}) does not match the official file. Delete it and download it again."),
        ["Err_ModelMissing"] = ("モデルファイルがありません。", "The model file is missing."),
    };
}
