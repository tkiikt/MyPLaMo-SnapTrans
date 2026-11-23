import Foundation
import SnapTransCore

/// UI strings (日本語 / English), same wording as the Windows build where the feature is the same.
/// "auto" follows the macOS preferred languages (Japanese first → 日本語, otherwise English).
enum Loc {
    nonisolated(unsafe) static var current = "ja-JP"
    static var japanese: Bool { current == "ja-JP" }

    static func resolve(_ setting: String) -> String {
        if setting == "ja-JP" || setting == "en-US" { return setting }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? "ja-JP" : "en-US"
    }

    /// PLaMo Community License (PFN): Japanese page for the Japanese UI, English page otherwise.
    static var licenseURL: URL {
        URL(string: japanese ? "https://plamo.preferredai.jp/info/plamo-community-license-ja"
                             : "https://plamo.preferredai.jp/info/plamo-community-license-en")!
    }

    static func t(_ key: String) -> String { table[key].map { japanese ? $0.0 : $0.1 } ?? key }
    static func f(_ key: String, _ args: CVarArg...) -> String { String(format: t(key), arguments: args) }

    static func error(_ e: Error) -> String {
        switch e {
        case let s as SnapTransError where table["Err_" + s.code] != nil:
            var text = t("Err_" + s.code)
            for (i, a) in s.args.enumerated() { text = text.replacingOccurrences(of: "{\(i)}", with: a) }
            return text.replacingOccurrences(of: #"\{\d\}"#, with: "", options: .regularExpression)
        case let s as SnapTransError: return s.description
        case is CancellationError: return t("Canceled")
        case let u as URLError where u.code == .cancelled: return t("Canceled")
        case is URLError: return t("Err_Network")
        default: return (e as NSError).localizedDescription
        }
    }

    static func size(_ bytes: Int64) -> String { bytes >= 1_000_000_000 ? String(format: "%.2f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6) }

    static let table: [String: (String, String)] = [
        "AppName": ("MyPLaMo SnapTrans", "MyPLaMo SnapTrans"),
        "Popup_Title": ("MyPLaMo SnapTrans · 翻訳", "MyPLaMo SnapTrans · Translation"),
        "Popup_TitleSource": ("MyPLaMo SnapTrans · 原文", "MyPLaMo SnapTrans · Original"),
        "Popup_Copy": ("コピー", "Copy"),
        "Popup_Copied": ("コピーしました", "Copied"),
        "Popup_Close": ("閉じる (Esc)", "Close (Esc)"),
        "Popup_ShowSource": ("原文を表示", "Show original"),
        "Popup_ShowTranslation": ("訳文を表示", "Show translation"),
        "Stage_Capturing": ("画面を取得中…", "Capturing…"),
        "Stage_Recognizing": ("文字を読み取り中…", "Reading text…"),
        "Stage_Loading": ("モデルを読み込み中（%@）…", "Loading model (%@)…"),
        "Stage_Translating": ("翻訳中…", "Translating…"),
        "Stage_Switching": ("翻訳エンジンを切り替えています…", "Switching the translation engine…"),
        "NoText": ("文字を読み取れませんでした。範囲を広げるか、OCR の言語を確認してください。", "No text was recognized. Try a larger area or check the OCR language."),
        "Canceled": ("キャンセルしました。", "Canceled."),
        "Fallback": ("Metal（GPU）を使えなかったため CPU で実行しています（%@）", "Running on CPU because Metal (GPU) could not be used (%@)"),

        "Menu_Settings": ("設定を開く…", "Open Settings…"),
        "Menu_Select": ("範囲を翻訳", "Translate Area"),
        "Menu_Last": ("最後の翻訳を表示", "Show Last Translation"),
        "Menu_Enabled": ("ドラッグ翻訳を有効にする", "Enable Drag-to-Translate"),
        "Menu_Quit": ("MyPLaMo SnapTrans を終了", "Quit MyPLaMo SnapTrans"),
        "Tip": ("MyPLaMo SnapTrans — %@ を押しながらドラッグ", "MyPLaMo SnapTrans — hold %@ and drag"),
        "Select_Hint": ("ドラッグで翻訳する範囲を選択 · Esc でキャンセル", "Drag to select the area to translate · Esc to cancel"),

        "Settings_Title": ("MyPLaMo SnapTrans 設定", "MyPLaMo SnapTrans Settings"),
        "Settings_Subtitle": ("画面をドラッグで囲んで、ローカルの PLaMo 3 Translate で翻訳します。", "Drag around any text on screen and translate it locally with PLaMo 3 Translate."),
        "BuiltWithPlamo": ("Built with PLaMo", "Built with PLaMo"),

        "Sec_Model": ("翻訳モデル", "Translation model"),
        "Model_Desc": ("PFN 公式の GGUF（Q4_K_M）を Hugging Face から直接ダウンロードします。まずは 0.8B（軽量）か 2B（高品質）がおすすめです。", "Downloads PFN's official GGUF (Q4_K_M) directly from Hugging Face. 0.8B (light) or 2B (better quality) is recommended."),
        "Model_Missing": ("未取得", "Not downloaded"),
        "Model_Partial": ("一部取得済み（%@）・再開できます", "Partially downloaded (%@) · can resume"),
        "Model_Ready": ("取得済み", "Downloaded"),
        "Model_InUse": ("使用中", "In use"),
        "Model_Unverified": ("取得済み・未検証（SHA-256 を確認します）", "Downloaded · not verified yet (SHA-256 check pending)"),
        "Model_VerifyingExisting": ("SHA-256 を確認しています…", "Checking SHA-256…"),
        "Model_Corrupt": ("ファイルが壊れています（サイズまたは SHA-256 が公式ファイルと不一致）。再ダウンロードしてください。", "The file is corrupt (size or SHA-256 differs from the official file). Please download it again."),
        "Model_Outdated": ("旧版（%@ 公開の公式ファイル）・使用できます。最新版への更新をおすすめします", "Older official file (published %@) · usable; updating is recommended"),
        "Model_Redownload": ("再ダウンロード", "Download again"),
        "Model_Download": ("ダウンロード", "Download"),
        "Model_Resume": ("再開", "Resume"),
        "Model_Use": ("使用する", "Use"),
        "Model_Delete": ("削除", "Delete"),
        "Model_Cancel": ("中断", "Pause"),
        "Model_Update": ("最新版を取得", "Get latest"),
        "Model_Large": ("大きいモデル（メモリに余裕がある Mac 向け）", "Large model (for Macs with plenty of memory)"),
        "Model_Huge": ("非常に大きいモデル（19.5 GB・ユニファイドメモリ 32 GB 以上推奨）", "Very large model (19.5 GB; 32 GB+ unified memory recommended)"),
        "Model_Progress": ("%@　%.1f%%　%@ / %@　%.1f MB/s", "%@　%.1f%%　%@ / %@　%.1f MB/s"),
        "Model_Verifying": ("SHA-256 を検証しています…", "Verifying SHA-256…"),
        "Model_Connecting": ("接続しています…", "Connecting…"),
        "Model_Downloaded": ("%@ をダウンロードして検証しました。", "%@ was downloaded and verified."),
        "Model_Paused": ("中断しました。「再開」で続きから取得します。", "Paused. Press Resume to continue."),
        "Model_Deleted": ("%@ を削除しました。", "%@ was deleted."),
        "Model_DeleteConfirm": ("%@ を削除しますか？", "Delete %@?"),
        "Model_Selected": ("%@ を使用します。", "Using %@."),
        "Folder": ("保存先", "Folder"),
        "Folder_Change": ("変更…", "Change…"),
        "Folder_Open": ("Finder で開く", "Show in Finder"),
        "Folder_Default": ("既定に戻す", "Use default"),
        "Folder_Pick": ("モデルの保存先を選択", "Choose the model folder"),
        "Folder_Note": ("保存先を変えると、そのフォルダーにある取得済みモデルを使います（ファイルは移動しません）。", "Changing the folder uses models already in it (files are not moved)."),
        "License_Link": ("PLaMo コミュニティライセンスを読む", "Read the PLaMo Community License"),
        "License_Agree": ("ライセンスを確認し、同意します（ダウンロードに必要です）", "I have read and agree to the license (required to download)"),
        "License_Required": ("ダウンロードの前にライセンスへの同意が必要です。", "Please agree to the license before downloading."),
        "Confirm_Download_Title": ("%@ をダウンロードしますか？", "Download %@?"),
        "Confirm_Download_Body": ("保存先「%@」に %@ のファイルを書き込みます。", "%2$@ will be written to \"%1$@\"."),
        "Confirm_Update_Title": ("%@ を最新版に更新しますか？", "Update %@ to the latest version?"),
        "Confirm_Update_Body": ("保存先「%@」に最新版（%@）をダウンロードし、検証できたら今のファイルと置き換えます。このフォルダーを他のアプリ（MyPLaMo など）と共有している場合は、そのアプリのファイルも置き換わります。", "The latest file (%2$@) is downloaded to \"%1$@\" and replaces the current one after verification. If another app (e.g. MyPLaMo) uses this folder, its file is replaced too."),
        "Confirm_Redownload_Title": ("%@ を再ダウンロードしますか？", "Download %@ again?"),
        "Confirm_Redownload_Body": ("壊れているファイルを削除し、保存先「%@」に %@ をダウンロードします。", "The corrupt file is deleted and %2$@ is downloaded to \"%1$@\"."),
        "Confirm_Delete_Body": ("次のファイルを削除します。他のアプリと共有しているフォルダーの場合は、そのアプリからも使えなくなります。\n%@", "This file will be deleted. If the folder is shared with another app, that app loses it too.\n%@"),

        "Sec_Device": ("実行デバイス", "Compute device"),
        "Device_Desc": ("自動では Metal（Apple シリコンの GPU）を使います。Metal で読み込めない場合は CPU に切り替えて理由を表示します。", "Automatic uses Metal (the Apple silicon GPU). If Metal cannot load the model, SnapTrans switches to CPU and shows why."),
        "Device_Auto": ("自動（Metal 優先）", "Automatic (Metal first)"),
        "Device_Cpu": ("CPU のみ", "CPU only"),
        "Device_Current": ("現在: %@", "Current: %@"),
        "Device_NotLoaded": ("現在: 未読み込み（最初の翻訳時に読み込みます）", "Current: not loaded (loads on first translation)"),
        "Device_Loaded": ("%@ · 読み込み %.1f 秒", "%@ · loaded in %.1f s"),

        "Sec_Shortcut": ("ショートカット", "Shortcut"),
        "Shortcut_Desc": ("選んだキーを押しながら画面のどこでも左ドラッグすると、その範囲を翻訳します。ドラッグ中は Esc でキャンセル。", "Hold the selected keys and left-drag anywhere on screen to translate that area. Press Esc while dragging to cancel."),
        "Shortcut_Need": ("キーを 1 つ以上選んでください。", "Select at least one key."),
        "Shortcut_Enabled": ("ドラッグ翻訳を有効にする", "Enable drag-to-translate"),
        "Tap_Conflict": ("ほかのアプリ（%@）もマウス操作を横取りできる状態です。同じキーの組み合わせを使っている場合は、ここで別の組み合わせにしてください。", "Another app (%@) can also intercept mouse input. If it uses the same keys, choose a different combination here."),
        "Shortcut_Remote": ("ほかのアプリ（音声入力やスクリーンショットのツールなど）と組み合わせがぶつかるときは、ここで変更できます。リモートデスクトップで操作しているときは、手元の PC のアプリが同じキー操作を先に受け取ることがあります。", "If another app (e.g. a dictation or screenshot tool) uses the same combination, change it here. Over remote desktop, an app on the local computer may receive the same keys first."),
        "Hotkey": ("「範囲を翻訳」のショートカット", "\"Translate Area\" shortcut"),
        "Hotkey_Desc": ("押すと範囲選択モードになります（ドラッグ操作の許可がなくても使えます）。メニューバーのアイコンを右クリックして「範囲を翻訳」を選んでも同じです。", "Starts area selection (works without the drag permission). The same as right-clicking the menu bar icon and choosing Translate Area."),
        "Hotkey_Record": ("変更…", "Change…"),
        "Hotkey_Recording": ("キーを押してください（Esc で取り消し）", "Press keys (Esc to cancel)"),
        "Hotkey_Clear": ("なし", "None"),
        "Hotkey_None": ("未設定", "Not set"),
        "Hotkey_Failed": ("このショートカットは他のアプリが使っているため登録できませんでした。", "This shortcut is in use by another app and could not be registered."),

        "Sec_Permissions": ("macOS の許可", "macOS permissions"),
        "Perm_Desc": ("必要になったときだけ許可を求めます。許可の追加・取り消しはシステム設定の「プライバシーとセキュリティ」で行います（SnapTrans が設定を変更することはありません）。", "SnapTrans asks only when a permission is needed. Permissions are granted or removed in System Settings → Privacy & Security (SnapTrans never changes your settings)."),
        "Perm_Screen": ("画面収録（選んだ範囲の文字を読むため）", "Screen Recording (to read the selected area)"),
        "Perm_Access": ("アクセシビリティ（修飾キー＋ドラッグを受け取るため）", "Accessibility (to receive modifier + drag)"),
        "Perm_Granted": ("許可済み", "Allowed"),
        "Perm_NotGranted": ("未許可", "Not allowed"),
        "Perm_Request": ("許可を求める", "Request"),
        "Perm_Open": ("システム設定を開く", "Open System Settings"),
        "Perm_ScreenNeeded": ("選んだ範囲を読み取るには「画面収録」の許可が必要です。システム設定 →「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で MyPLaMo SnapTrans をオンにしてください。", "Reading the selected area needs the Screen Recording permission. Turn on MyPLaMo SnapTrans in System Settings → Privacy & Security → Screen & System Audio Recording."),
        "Perm_AccessNote": ("許可がなくても、メニューの「範囲を翻訳」とショートカットで翻訳できます。", "Without it, Translate Area (menu or shortcut) still works."),
        "Perm_Restart": ("許可を変えた後に反映されない場合は、アプリを終了して起動し直してください。", "If a change does not take effect, quit and reopen the app."),
        "Tap_Active": ("ドラッグ翻訳: 動作中", "Drag-to-translate: active"),
        "Tap_Inactive": ("ドラッグ翻訳: 停止中（アクセシビリティの許可が必要です）", "Drag-to-translate: inactive (needs the Accessibility permission)"),
        "Tap_Disabled": ("ドラッグ翻訳: オフ", "Drag-to-translate: off"),

        "Sec_Translation": ("翻訳", "Translation"),
        "Target": ("訳先の言語", "Translate into"),
        "Target_Auto": ("自動（日本語 ⇄ 英語）", "Automatic (Japanese ⇄ English)"),
        "Target_Desc": ("翻訳元の言語はモデルが自動で判定します。", "The source language is detected by the model."),

        "Sec_Ocr": ("文字認識（OCR）", "Text recognition (OCR)"),
        "Ocr_Desc": ("macOS の Vision（高精度モード）で読み取ります。画面の内容が外部に送られることはありません。", "Uses macOS Vision (accurate mode). Nothing on your screen leaves the Mac."),
        "Ocr_Language": ("OCR の言語", "OCR language"),
        "Ocr_Auto": ("自動（日本語・英語を判定）", "Automatic (detect Japanese / English)"),
        "Ocr_Ja": ("日本語（英語混じりも可）", "Japanese (with English)"),
        "Ocr_En": ("英語", "English"),

        "Sec_Appearance": ("表示", "Appearance"),
        "UiLanguage": ("表示言語", "Display language"),
        "UiLanguage_Auto": ("自動（macOS に合わせる）", "Automatic (match macOS)"),
        "Theme": ("テーマ", "Theme"),
        "Theme_System": ("システム設定に従う", "Use system setting"),
        "Theme_Light": ("ライト", "Light"),
        "Theme_Dark": ("ダーク", "Dark"),

        "Sec_Last": ("最後の翻訳", "Last translation"),
        "Last_None": ("まだ翻訳していません。", "Nothing translated yet."),
        "Last_Source": ("原文", "Original"),
        "Last_Result": ("訳文", "Translation"),

        "Sec_About": ("このアプリについて", "About"),
        "About_Text": ("MyPLaMo SnapTrans %@（macOS）\n翻訳モデル: PLaMo 3 Translate（Preferred Networks）。モデルは PLaMo コミュニティライセンスに従います。\n推論エンジン: llama.cpp %@（MIT License）。OCR: Apple Vision。\n株式会社 Preferred Networks が公開した翻訳モデルを使用する個人開発の非公式アプリです。同社による提供・推奨・提携はありません。", "MyPLaMo SnapTrans %@ (macOS)\nTranslation model: PLaMo 3 Translate (Preferred Networks), under the PLaMo Community License.\nInference engine: llama.cpp %@ (MIT License). OCR: Apple Vision.\nAn unofficial, independently developed app; not provided, endorsed, or affiliated with Preferred Networks, Inc."),
        "Cancel": ("キャンセル", "Cancel"),

        "Err_Network": ("ネットワークに接続できませんでした。", "Could not connect to the network."),
        "Err_NoModel": ("翻訳モデルがありません。設定画面でダウンロードしてください。", "No translation model. Download one in Settings."),
        "Err_DiskFull": ("保存先の空き容量が足りません（あと {0} バイト必要）。", "Not enough free space ({0} more bytes needed)."),
        "Err_HttpError": ("ダウンロードに失敗しました（HTTP {0}）。", "Download failed (HTTP {0})."),
        "Err_HashMismatch": ("SHA-256 が一致しません。ファイルを削除しました。もう一度ダウンロードしてください。", "SHA-256 mismatch. The file was deleted; please download again."),
        "Err_ExistingHashMismatch": ("保存先のファイルが公式ファイルと一致しません。削除して再取得してください。", "The file in the folder does not match the official file. Delete and download again."),
        "Err_Interrupted": ("ダウンロードが途中で止まりました。「再開」で続きから取得します。", "The download stopped. Press Resume to continue."),
        "Err_ResumeMismatch": ("再開位置が一致しません。", "Resume position mismatch."),
        "Err_SizeMismatch": ("配布元のファイルサイズが一致しません。", "The server file size does not match."),
        "Err_FolderNotAbsolute": ("保存先を絶対パスで指定してください。", "Please choose an absolute folder path."),
        "Err_DownloadInProgress": ("このモデルは別のプロセスがダウンロード中です。", "This model is being downloaded by another process."),
        "Err_FolderNotWritable": ("保存先に書き込めません。", "The folder is not writable."),
        "Err_EngineMissing": ("推論エンジンが見つかりません。", "Inference engine not found."),
        "Err_EngineExited": ("推論エンジンが終了しました（コード {0}）。{1}", "The inference engine exited (code {0}). {1}"),
        "Err_EngineTimeout": ("モデルの読み込みがタイムアウトしました。", "Model loading timed out."),
        "Err_NotOffloaded": ("GPU にモデルを配置できませんでした", "the model could not be placed on the GPU"),
        "Err_TranslateHttp": ("翻訳できませんでした（{0}）。", "Translation failed ({0})."),
        "Err_TooLong": ("文章が長すぎます。範囲を分けてください。", "The text is too long. Select a smaller area."),
        "Err_EmptyResult": ("訳文が空でした。", "The translation was empty."),
        "Err_ControlTokens": ("モデルの制御記号を含む文章は翻訳できません。", "Text containing model control tokens cannot be translated."),
        "Err_BadLanguage": ("翻訳言語が正しくありません。", "Invalid translation language."),
        "Err_ModelVerifying": ("モデルファイルを確認中です（SHA-256）。少し待ってからもう一度お試しください。", "Checking the model file (SHA-256). Please try again in a moment."),
        "Err_PortInUse": ("ローカルのポート {0} を使えませんでした", "local port {0} was unavailable"),
        "Err_TranslateTimeout": ("翻訳が時間内に終わりませんでした。範囲を小さくしてください。", "Translation timed out. Select a smaller area."),
        "Err_EngineNotLoaded": ("翻訳エンジンが起動していません。", "The translation engine is not running."),
        "Err_EngineTampered": ("推論エンジン（{0}）のファイルが公式版と一致しないため起動しませんでした（{1}）。アプリを入れ直してください。", "The inference engine ({0}) does not match the official files and was not started ({1}). Please reinstall the app."),
        "Err_EngineUnexpectedResponse": ("推論エンジンから想定外の応答がありました（{0}）。翻訳を中止しました。", "Unexpected response from the inference engine ({0}). Translation was stopped."),
        "Err_ModelMissing": ("モデルファイルがありません。", "The model file is missing."),
        "Err_CaptureDenied": ("画面収録の許可がないため、選んだ範囲を読み取れませんでした。設定画面の「macOS の許可」を確認してください。", "The selected area could not be read because Screen Recording is not allowed. See \"macOS permissions\" in Settings."),
        "Err_CaptureFailed": ("画面を取得できませんでした。", "The screen could not be captured."),
        "Err_ImageUnreadable": ("画像を読み込めませんでした。", "The image could not be read."),
    ]
}
