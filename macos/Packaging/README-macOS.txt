MyPLaMo SnapTrans v{VERSION} - macOS (Apple Silicon / arm64)
=========================================================

[日本語]  (English below)

画面の文字をドラッグで囲むと、その場で翻訳するメニューバー常駐アプリです。
文字の読み取り（Apple Vision OCR）も翻訳も、すべてこの Mac の中で処理し、
画面の内容や文章を外部に送信しません。翻訳には株式会社 Preferred Networks の
翻訳モデル PLaMo 3 Translate を使用します。

Built with PLaMo

株式会社 Preferred Networks が公開した翻訳モデル「PLaMo 3 Translate」を使用する、
個人開発の非公式アプリです。株式会社 Preferred Networks による提供・推奨・提携はありません。

■ 動作環境
- OS: macOS 15 以降、Apple シリコン（M1 以降 / arm64）
- メモリ: 8 GB 以上を推奨（8B モデルは余裕のあるメモリ、31B モデルはユニファイドメモリ 32 GB 以上を推奨）
- 実行デバイス: Metal（Apple シリコンの GPU）で動作します。設定で CPU のみに切り替えることもできます
- ディスク: アプリ本体 約 35 MB、翻訳モデル 0.6 GB（0.8B）〜 19.5 GB（31B）
- ネットワーク: 翻訳モデルのダウンロード時のみ必要

■ 使い方
1. ZIP を展開し、「MyPLaMo SnapTrans.app」をそのまま起動するか、
   「アプリケーション」（/Applications）フォルダーに移動して起動します。
   Dock には出ず、メニューバーにアイコンが表示されます。
2. 初回は設定画面が開きます。PLaMo コミュニティライセンスを確認して同意にチェックを付け、
   翻訳モデルをダウンロードします（まずは 0.8B か 2B がおすすめです）。
   この ZIP にモデルは同梱していません。モデルは PFN の Hugging Face から直接ダウンロードします。
3. 必要な許可（「画面収録」「アクセシビリティ」）を付与します（下の「必要な許可」を参照）。
4. 翻訳する:
   - Control + Shift を押しながら画面上の文字を左ドラッグで囲むと、離したときに翻訳ポップアップが表示されます。
   - Control + Shift + T（またはメニューバーアイコン右クリック →「範囲を翻訳」）でも範囲選択を開始できます。
   - ドラッグ中に Esc でキャンセルできます。ポップアップは × または Esc で閉じ、ドラッグで移動できます。
   - ポップアップのボタンで原文⇄訳文の切り替え、コピーができます。
   - ほかのアプリとキーの組み合わせが重なる場合は、設定画面の「ショートカット」で変更できます。
     （Control + Option は VoiceOver や一部の音声入力アプリと重なるため既定にしていません。）
5. メニューバーのアイコン:
   - クリックで設定を開きます。
   - 右クリック（または Control + クリック）で「範囲を翻訳 / 最後の翻訳を表示 /
     ドラッグ翻訳を有効にする / 設定を開く… / MyPLaMo SnapTrans を終了」を選べます。
   - アプリを終了するときはメニューバーから「MyPLaMo SnapTrans を終了」を選んでください。

■ ダウンロードしたファイルの確認（SHA-256）
配布ページに載っている SHA-256（または同梱の .sha256 ファイル）と、
ダウンロードした ZIP の値が一致するか確認できます。
ターミナルで次を実行し、表示された 64 文字が配布ページの値と一致することを確かめてください:
  shasum -a 256 ~/Downloads/MyPLaMo-SnapTrans-{VERSION}-macos-arm64.zip
同じフォルダーに .sha256 ファイルがある場合は、次でも照合できます:
  shasum -a 256 -c MyPLaMo-SnapTrans-{VERSION}-macos-arm64.zip.sha256
一致しない場合は ZIP を開かずに削除し、配布ページからダウンロードし直してください。

■ 署名なし Mac アプリの開き方
このアプリは Apple の公証（Notarization）および Developer ID による配布署名を行っていません
（配布用ビルドは ad hoc 署名＋Hardened Runtime）。初回起動時に「開発元を検証できません」
「開けません」などの警告が表示されます。配布元を信頼できる場合は、次の手順で開けます:
  「システム設定」→「プライバシーとセキュリティ」→ 下の方の「このまま開く」→ 確認画面で「開く」

■ 必要な許可
設定画面の「macOS の許可」で許可状態を確認できます。許可は「システム設定」→
「プライバシーとセキュリティ」で行います。変更が反映されないときはアプリを再起動してください。
※ ad hoc 署名のためビルドごとにコード ID が変わります。更新版をインストールしたときは、
  システム設定で「画面収録」「アクセシビリティ」の許可を付け直してください
  （一度オフ→オン、または一覧から「-」で削除して追加し直す）。
- 画面収録: 選んだ範囲の文字を読み取るために必要です。
- アクセシビリティ: Control + Shift を押しながらのドラッグを受け取るために必要です。
  （アクセシビリティを許可しない場合でも、Control + Shift + T またはメニューの「範囲を翻訳」で翻訳できます。）
- 画面収録の確認ダイアログについて:
  画面収録を許可した後の最初の翻訳時、macOS が「システムプライベートウインドウピッカーをバイパスして
  画面とオーディオに直接アクセスすることが要求されています」と確認します。「許可」で続行してください。
  macOS の仕様により、この確認ダイアログはおおむね毎月表示されます（アプリ側からは止められません）。
  なお、このアプリは音声を一切取得しません。

■ データの保存場所とアンインストール
- 設定・ログ・検証結果:
    ~/Library/Application Support/MyPLaMo-SnapTrans
- 翻訳モデル（*.gguf）:
    設定画面の「保存先」（既定は ~/Library/Application Support/MyPLaMo-SnapTrans/models）
- アンインストール方法:
  1. メニューバーのアイコンから「MyPLaMo SnapTrans を終了」を選んでアプリを終了します。
  2. 「MyPLaMo SnapTrans.app」（および展開したフォルダー）を削除します。
  3. 設定・ログ・モデルも削除する場合は、~/Library/Application Support/MyPLaMo-SnapTrans フォルダーを
     削除してください（別のフォルダーをモデルの保存先にした場合は、そのフォルダーの *.gguf も削除してください）。
  4. 必要に応じて、「システム設定」→「プライバシーとセキュリティ」の「画面収録」「アクセシビリティ」の
     一覧から MyPLaMo SnapTrans を「-」で削除します。

■ モデルとライセンス
- 翻訳モデル PLaMo 3 Translate はこの配布物に含まれていません。モデルを利用するには、
  PLaMo コミュニティライセンス契約への同意が必要です:
    日本語: https://plamo.preferredai.jp/info/plamo-community-license-ja
    English: https://plamo.preferredai.jp/info/plamo-community-license-en
- MyPLaMo SnapTrans 本体: MIT License（同梱の LICENSE.txt を参照）
- 同梱している第三者ソフトウェア（llama.cpp b12121 など）: 同梱の THIRD-PARTY-NOTICES.txt を参照


[English]

MyPLaMo SnapTrans is a menu bar app for macOS that translates any text on your screen:
drag a box around it and the translation pops up. Text recognition (Apple Vision OCR) and
translation both run locally on this Mac; nothing on your screen is sent externally.
Translation uses PLaMo 3 Translate by Preferred Networks, Inc.

Built with PLaMo

An unofficial, independently developed app that uses the PLaMo 3 Translate model released by
Preferred Networks, Inc. It is not provided, endorsed, or affiliated with Preferred Networks, Inc.

* Requirements
- OS: macOS 15 or later, Apple silicon (M1 or later / arm64)
- Memory: 8 GB or more recommended (more for 8B; 32 GB+ unified memory recommended for 31B)
- Compute device: Runs on Metal (Apple silicon GPU); can also be switched to CPU only in Settings
- Disk space: ~35 MB for the app; 0.6 GB (0.8B) to 19.5 GB (31B) for a translation model
- Network: Required only when downloading translation models

* Usage
1. Extract the ZIP and launch "MyPLaMo SnapTrans.app" directly, or move it to /Applications first.
   It lives in the menu bar (no Dock icon).
2. Settings opens on first launch. Read and agree to the PLaMo Community License, then download
   a translation model (0.8B or 2B is recommended to start).
   No model is bundled in this ZIP; models are downloaded directly from PFN's Hugging Face repositories.
3. Grant the required macOS permissions (Screen Recording and Accessibility; see "Required permissions" below).
4. Translate text on screen:
   - Hold Control + Shift and left-drag around text; release to show the translation popup.
   - Or press Control + Shift + T (or right-click the menu bar icon -> "Translate Area") to select an area.
   - Press Esc while dragging to cancel. Close the popup with x or Esc, and drag the card to move it.
   - Use the popup buttons to switch between original and translation, or copy text.
   - If the shortcut conflicts with another app, change it in Settings -> Shortcut.
     (Control + Option is not the default because VoiceOver and some dictation tools use it.)
5. Menu bar icon:
   - Left-click opens Settings.
   - Right-click (or Control-click) opens the menu: "Translate Area / Show Last Translation /
     Enable Drag-to-Translate / Open Settings... / Quit MyPLaMo SnapTrans".
   - To exit, choose "Quit MyPLaMo SnapTrans" from the menu bar icon.

* Verifying the download (SHA-256)
Compare the SHA-256 of the downloaded ZIP with the value published on the release page
(or with the accompanying .sha256 file):
  shasum -a 256 ~/Downloads/MyPLaMo-SnapTrans-{VERSION}-macos-arm64.zip
Or, with the .sha256 file in the same folder:
  shasum -a 256 -c MyPLaMo-SnapTrans-{VERSION}-macos-arm64.zip.sha256
If the 64 characters differ, delete the ZIP without opening it and download it again.

* Opening an unsigned macOS app
This app is not notarized or signed with an Apple Developer ID (distributed with ad hoc signing
and Hardened Runtime), so macOS will warn that it cannot verify the developer on first launch.
If you trust the source, open it via:
  System Settings -> Privacy & Security -> click "Open Anyway" near the bottom -> confirm "Open"

* Required permissions
Check permission status in Settings -> "macOS permissions", and manage them in
System Settings -> Privacy & Security. Quit and reopen the app if a change does not take effect.
Note: Because ad hoc signing changes the code identity with each build, re-grant Screen Recording
and Accessibility after installing an update (toggle off/on, or remove with "-" and add again).
- Screen Recording: Required to read text in the selected area.
- Accessibility: Required to receive Control + Shift + drag.
  (Without Accessibility, Control + Shift + T and "Translate Area" from the menu still work.)
- Monthly Screen Recording confirmation dialog:
  On the first translation after granting Screen Recording, macOS asks whether the app may
  "bypass the system private window picker and directly access your screen and audio"; choose Allow.
  By macOS design, this confirmation dialog appears roughly once a month (the app cannot disable it).
  No audio is ever captured.

* Data locations and uninstalling
- Settings, log, and verification results:
    ~/Library/Application Support/MyPLaMo-SnapTrans
- Translation models (*.gguf):
    The "Folder" set in Settings (default: ~/Library/Application Support/MyPLaMo-SnapTrans/models)
- How to uninstall:
  1. Choose "Quit MyPLaMo SnapTrans" from the menu bar icon.
  2. Delete "MyPLaMo SnapTrans.app" (and the extracted folder).
  3. To remove settings, logs, and models as well, delete ~/Library/Application Support/MyPLaMo-SnapTrans
     (if you chose another model folder, delete the *.gguf files there too).
  4. Optionally remove MyPLaMo SnapTrans from the Screen Recording and Accessibility lists
     in System Settings -> Privacy & Security using the "-" button.

* Models and licenses
- The PLaMo 3 Translate model is NOT bundled in this distribution. Using the model requires
  agreeing to the PLaMo Community License Agreement:
    English: https://plamo.preferredai.jp/info/plamo-community-license-en
    Japanese: https://plamo.preferredai.jp/info/plamo-community-license-ja
- MyPLaMo SnapTrans app: MIT License (see LICENSE.txt)
- Bundled third-party software (llama.cpp b12121, etc.): see THIRD-PARTY-NOTICES.txt
