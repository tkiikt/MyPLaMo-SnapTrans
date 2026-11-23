MyPLaMo SnapTrans {VERSION} for macOS
=====================================

[日本語]  (English below)

画面の文字をドラッグで囲むと、その場で翻訳するメニューバー常駐アプリです。
文字の読み取り（OCR）も翻訳も、すべてこの Mac の中で行います。翻訳には
Preferred Networks の翻訳モデル PLaMo 3 Translate を使います。

株式会社 Preferred Networks が公開した翻訳モデル「PLaMo 3 Translate」を使用する、
個人開発の非公式アプリです。株式会社 Preferred Networks による提供・推奨・提携はありません。

Built with PLaMo

■ 動作環境
- macOS 15 以降、Apple シリコン（M1 以降）。
- メモリ 8 GB 以上を推奨。Metal（GPU）で動きます。CPU のみにも切り替えられます。
- モデルの保存に 0.6 GB〜の空き容量。初回のダウンロードにインターネット接続。

■ はじめかた
1. ZIP を展開し、「MyPLaMo SnapTrans.app」を「アプリケーション」フォルダーなどに移します。
2. 起動します。Dock には出ず、メニューバーにアイコンが出ます。
   このアプリは Apple の公証を受けていないため、初回は「開発元を検証できません」と表示されます。
   配布元を信頼できる場合は、システム設定 →「プライバシーとセキュリティ」→ 下の方の
   「このまま開く」で起動できます。
3. 初回は設定画面が開きます。PLaMo コミュニティライセンスを読み、同意にチェックを付けてから、
   翻訳モデルを「ダウンロード」します（まずは 0.8B か 2B）。モデルは PFN の Hugging Face から直接取得します。
4. 許可（設定画面の「macOS の許可」で状態を確認できます）:
   - 画面収録: 選んだ範囲の文字を読むために必要です。
   - アクセシビリティ: Control + Option を押しながらのドラッグを受け取るために必要です。
   許可はシステム設定 →「プライバシーとセキュリティ」で行います。変更が反映されないときはアプリを再起動します。
5. Control + Option を押しながら、画面上の文字を左ドラッグで囲みます。離すと翻訳がポップアップで表示されます。
   - ドラッグ中に Esc でキャンセル。ポップアップは × か Esc で閉じます。ポップアップはドラッグで動かせます。
   - ポップアップのボタン: 原文⇄訳文の切り替え、コピー。
   - アクセシビリティを許可しない場合も、メニューの「範囲を翻訳」か Control + Option + T で範囲を選べます。
6. メニューバーのアイコン: クリックで設定、右クリックで「範囲を翻訳 / 最後の翻訳を表示 /
   ドラッグ翻訳を有効にする / 設定を開く / 終了」。

■ データの保存場所とアンインストール
- 設定・ログ・検証結果: ~/Library/Application Support/MyPLaMo-SnapTrans
- 翻訳モデル: 設定画面の「保存先」（既定は ~/Library/Application Support/MyPLaMo-SnapTrans/models）
- アンインストール: メニューから「終了」し、アプリを削除します。データも消すときは上のフォルダーを削除し、
  システム設定の「画面収録」「アクセシビリティ」の一覧から MyPLaMo SnapTrans を「-」で取り除きます。

■ ライセンス
- MyPLaMo SnapTrans 本体: MIT License（アプリ内 Contents/Resources/licenses）
- 翻訳モデル PLaMo 3 Translate: PLaMo コミュニティライセンス契約（Preferred Networks）
    https://plamo.preferredai.jp/info/plamo-community-license-ja
- 推論エンジン llama.cpp b12121（MIT License、アプリに同梱）


[English]

MyPLaMo SnapTrans is a menu bar app that translates any text on your screen: drag a box around it and the
translation pops up. Text recognition (OCR) and translation both run on this Mac, using PLaMo 3 Translate,
the translation model by Preferred Networks.

An unofficial, independently developed app that uses the PLaMo 3 Translate model released by
Preferred Networks, Inc. It is not provided, endorsed, or affiliated with Preferred Networks, Inc.

Built with PLaMo

* Requirements: macOS 15 or later on Apple silicon; 8 GB of memory or more recommended; 0.6 GB or more of free
  disk space for a model and an internet connection for the first download.

* Getting started
1. Unzip and move "MyPLaMo SnapTrans.app" to Applications. It lives in the menu bar (no Dock icon).
   The app is not notarized, so macOS says it cannot verify the developer the first time. If you trust the source,
   open System Settings → Privacy & Security and click "Open Anyway".
2. Settings opens on first launch: read and accept the PLaMo Community License, then download a model
   (0.8B or 2B to start). Models come directly from PFN's Hugging Face repositories.
3. Permissions (status in Settings → macOS permissions): Screen Recording (to read the selected area) and
   Accessibility (to receive Control + Option + drag). Grant them in System Settings → Privacy & Security; restart
   the app if a change does not take effect.
4. Hold Control + Option and left-drag around text. Esc cancels; × or Esc closes the card; drag the card to move it.
   Without Accessibility, use "Translate Area" in the menu or Control + Option + T.

* Data: settings, log and verification results in ~/Library/Application Support/MyPLaMo-SnapTrans; models in the
  folder chosen in Settings. To uninstall, quit from the menu, delete the app and that folder, and remove the app
  from the Screen Recording / Accessibility lists in System Settings.

* Licenses: MyPLaMo SnapTrans – MIT; PLaMo 3 Translate – PLaMo Community License (Preferred Networks)
  https://plamo.preferredai.jp/info/plamo-community-license-en ; llama.cpp b12121 – MIT (bundled).
