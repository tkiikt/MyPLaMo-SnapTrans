MyPLaMo SnapTrans v{VERSION} - Windows x64
========================================

[日本語]  (English below)

画面の文字をドラッグで囲むと、その場で翻訳するタスクトレイ常駐アプリです。
文字の読み取り（OCR）も翻訳も、すべてこの PC の中で行います。翻訳には
Preferred Networks の翻訳モデル PLaMo 3 Translate を使います。

株式会社 Preferred Networks が公開した翻訳モデル「PLaMo 3 Translate」を使用する、
個人開発の非公式アプリです。株式会社 Preferred Networks による提供・推奨・提携はありません。

Built with PLaMo

■ 動作環境
- Windows 10 (2004 以降) / Windows 11、64 ビット (x64)
- メモリ 8 GB 以上を推奨（8B / 31B モデルはさらに必要）
- GPU 任意（NVIDIA / AMD / Intel の Vulkan 対応 GPU で高速動作。NVIDIA GPU は設定から
  CUDA エンジンも導入できます。GPU がなくても CPU のみで動作します）
- モデルの保存に 0.6 GB〜（モデルの大きさによる）の空き容量。初回のダウンロードにインターネット接続。

■ 使い方
1. 必要に応じてダウンロードした ZIP の SHA-256 を .sha256 ファイルと照合し、好きな場所（例: C:\Tools）に展開します。
   PowerShell での確認例:
     Get-FileHash .\MyPLaMo-SnapTrans-{VERSION}-win-x64.zip -Algorithm SHA256
2. MyPLaMo-SnapTrans フォルダーの MyPLaMo-SnapTrans.exe を起動します。
   インストール不要、管理者権限不要、.NET などの追加インストールも不要です。
   app フォルダーには本体とランタイム一式が入っています。消したり移動したりせず、
   フォルダーごと置いてください（app\MyPLaMo.SnapTrans.exe を直接起動しても同じです）。
3. 初回は設定画面が開きます。PLaMo コミュニティライセンスを読み、同意にチェックを付けてから、
   翻訳モデルを「ダウンロード」します（まずは 0.8B か 2B）。モデルは PFN の Hugging Face から直接取得します。
   この ZIP にモデルは同梱していません。
4. Ctrl + Alt を押しながら、画面上の文字を左ドラッグで囲みます。離すと翻訳がポップアップで表示されます。
   - ドラッグ中に Esc でキャンセル。ポップアップは × か Esc で閉じます。
   - ポップアップのボタン: 原文⇄訳文の切り替え、コピー。
5. 通知領域（タスクトレイ）のアイコン: クリックで設定、右クリックで
   「設定を開く / 最後の翻訳を表示 / ドラッグ翻訳を有効にする / 終了」。
   終了するときはトレイメニューから「終了」を選んでください。

■ 「Windows によって PC が保護されました」と表示されたら（SmartScreen）
このアプリはコード署名されていないため、初回起動時に Microsoft Defender SmartScreen が
「発行元: 不明」と警告することがあります。配布元を信頼できる場合は
「詳細情報」→「実行」で起動できます。

■ 文字の読み取り精度を上げるには
Windows OCR は、Windows に入っている言語の OCR で読み取ります。英語の画面を訳すなら、
Windows の［設定］→［時刻と言語］→［言語と地域］→［言語の追加］で「英語（米国）」を追加して、
言語機能のダウンロードが終わるまで待ってください。設定画面の「Windows の言語設定を開く」から開けます。

■ データの保存場所とアンインストール
- 設定・ログ・検証結果・CUDA エンジン・Tesseract の辞書:
    %LOCALAPPDATA%\MyPLaMo-SnapTrans
- 翻訳モデル: 設定画面の「保存先」（既定は %LOCALAPPDATA%\MyPLaMo-SnapTrans\models）
- アンインストール: アンインストール前に設定画面で「サインイン時に起動する」をオフにし、
  通知領域のアイコンを右クリックして「終了」してから、展開したフォルダーを削除します。
  データも消すときは、上の %LOCALAPPDATA%\MyPLaMo-SnapTrans フォルダーと、
  別の場所を保存先にした場合はそのフォルダーのモデル（*.gguf）を削除します。
- レジストリは、設定画面で「サインイン時に起動する」をオンにしたときだけ
  HKCU\Software\Microsoft\Windows\CurrentVersion\Run（値名 MyPLaMo SnapTrans）に書き込みます。
  オフにすると削除されます（既定はオフ）。

■ モデルとライセンス
- 翻訳モデル PLaMo 3 Translate はこの ZIP に同梱していません。利用者が設定画面で
  PLaMo コミュニティライセンスに同意したうえで、PFN の Hugging Face から直接ダウンロードして使用します。
  PLaMo コミュニティライセンス契約（Preferred Networks）:
    日本語: https://plamo.preferredai.jp/info/plamo-community-license-ja
    English: https://plamo.preferredai.jp/info/plamo-community-license-en
- MyPLaMo SnapTrans 本体: MIT License（LICENSE.txt）
- 同梱しているソフトウェア（llama.cpp、.NET、Windows App SDK、Visual C++ ランタイム、Tesseract など）:
  THIRD-PARTY-NOTICES.txt
  同梱している Microsoft のコンポーネント（Windows App SDK、.NET、Visual C++ ランタイムなど）は、
  それぞれの Microsoft のライセンス条件に従います。MIT License は MyPLaMo SnapTrans 本体に
  適用されるもので、これらのコンポーネントの条件を変えるものではありません。


[English]

MyPLaMo SnapTrans is a system tray app that translates any text on your screen: drag a box around it and
the translation pops up. Text recognition (OCR) and translation both run locally on this PC. Translation
uses PLaMo 3 Translate, the translation model by Preferred Networks.

An unofficial, independently developed app that uses the PLaMo 3 Translate model released by
Preferred Networks, Inc. It is not provided, endorsed, or affiliated with Preferred Networks, Inc.

Built with PLaMo

* Requirements
- Windows 10 (version 2004 or later) / Windows 11, 64-bit (x64)
- 8 GB of memory or more recommended (more for the 8B / 31B models)
- GPU optional (fast on Vulkan-capable NVIDIA / AMD / Intel GPUs; NVIDIA GPUs can also install the
  optional CUDA engine from Settings; runs on CPU alone as well)
- 0.6 GB or more of free disk space for a model (depends on the model size), and an internet
  connection for the first download.

* Usage
1. Optionally verify the downloaded ZIP against the .sha256 file, then extract it anywhere (for example C:\Tools).
   PowerShell example:
     Get-FileHash .\MyPLaMo-SnapTrans-{VERSION}-win-x64.zip -Algorithm SHA256
2. Start MyPLaMo-SnapTrans.exe in the MyPLaMo-SnapTrans folder.
   No installation, no administrator rights, no .NET or other runtime to install.
   The app folder holds the program and its runtime. Do not delete or move it; keep the whole
   folder together (starting app\MyPLaMo.SnapTrans.exe directly works the same).
3. The first time, Settings opens. Read the PLaMo Community License, tick the agreement, then
   "Download" a translation model (start with 0.8B or 2B). Models are downloaded directly from
   PFN's Hugging Face repositories. No model is bundled in this ZIP.
4. Hold Ctrl + Alt and drag a box around text on the screen with the left mouse button.
   When you release it, the translation appears in a popup.
   - Esc cancels the drag. Close the popup with x or Esc.
   - Popup buttons: switch between original and translation, copy.
5. Notification area (system tray) icon: click for Settings; right-click for
   "Open settings / Show last translation / Enable drag-to-translate / Exit".
   Choose "Exit" from the tray menu when you want to quit.

* "Windows protected your PC" (SmartScreen)
The app is not code-signed, so Microsoft Defender SmartScreen may warn "Unknown publisher" the first time.
If you trust where you got it from, click "More info" and then "Run anyway".

* Better text recognition
Windows OCR reads text with the OCR languages installed in Windows. To translate English
screens, add "English (United States)" in Windows Settings > Time & language >
Language & region > Add a language, and wait until its language features are downloaded.
The "Open Windows language settings" button in Settings takes you there.

* Where data is stored / uninstalling
- Settings, log, verification results, CUDA engine, Tesseract data:
    %LOCALAPPDATA%\MyPLaMo-SnapTrans
- Translation models: the "Folder" setting in Settings
  (default %LOCALAPPDATA%\MyPLaMo-SnapTrans\models)
- To uninstall: turn off "Start at sign-in" in Settings before uninstalling, right-click the
  notification area icon, choose "Exit", and delete the extracted folder.
  To remove your data as well, delete %LOCALAPPDATA%\MyPLaMo-SnapTrans and, if you chose
  another model folder, the models (*.gguf) in it.
- Nothing is written to the registry unless you turn on "Start at sign-in" in Settings, which adds
  one value ("MyPLaMo SnapTrans") under HKCU\Software\Microsoft\Windows\CurrentVersion\Run
  (off by default; turning it off removes the value).

* Models and licenses
- The PLaMo 3 Translate model is NOT bundled in this ZIP. Users agree to the PLaMo Community License
  in Settings and download the model directly from PFN's Hugging Face repositories.
  PLaMo Community License Agreement (Preferred Networks):
    English: https://plamo.preferredai.jp/info/plamo-community-license-en
    Japanese: https://plamo.preferredai.jp/info/plamo-community-license-ja
- MyPLaMo SnapTrans itself: MIT License (LICENSE.txt)
- Bundled software (llama.cpp, .NET, Windows App SDK, Visual C++ runtime, Tesseract and others):
  THIRD-PARTY-NOTICES.txt
  The bundled Microsoft components (Windows App SDK, .NET, Visual C++ runtime and others) are
  subject to their respective Microsoft license terms. The MIT License applies to MyPLaMo SnapTrans
  itself and does not change the terms of those components.
