# MyPLaMo SnapTrans for macOS（開発者向けドキュメント）

[日本語](#日本語) | [English](#english) | [ルート README](../README.md)

**Built with PLaMo**

> 株式会社 Preferred Networks が公開した翻訳モデル「PLaMo 3 Translate」を使用する、個人開発の非公式アプリです。株式会社 Preferred Networks による提供・推奨・提携はありません。
>
> An unofficial, independently developed app that uses the PLaMo 3 Translate model released by Preferred Networks, Inc. It is not provided, endorsed, or affiliated with Preferred Networks, Inc.

---

## 日本語

### 概要

MyPLaMo SnapTrans の macOS 版（Apple Silicon / arm64、メニューバー常駐アプリ）の開発者向けガイドです。利用者向けの全体概要・使い方・ライセンス案内は [ルート README](../README.md)（および配布 ZIP 内の `README.txt`）を参照してください。

- **Control + Shift + ドラッグ**（または **Control + Shift + T** / メニューの「範囲を翻訳」）で選択した範囲を Apple Vision OCR で読み取り、ローカルの **PLaMo 3 Translate**（`llama.cpp`、Metal / CPU）で翻訳します。
- モデルカタログ、PFML3 プロンプト形式、ダウンロード／SHA-256 検証ルール、ポップアップデザインは Windows 版（`../src`）と共通です。

### 構成

| パス | 内容 |
| --- | --- |
| `Sources/SnapTransCore` | モデルカタログ（`Resources/catalog.json`。`../src/SnapTrans.Core/catalog.json` と同一であることをテストで検証）、再開・SHA-256 検証付きダウンロード、検証キャッシュ、PFML3 プロンプト、OCR 行結合、言語定義 |
| `Sources/SnapTransEngine` | `llama-server` 子プロセス制御（所有者専用 0700 フォルダー内の Unix ドメインソケット、接続ごとの相手 PID（`LOCAL_PEERPID`）＋起動時刻の照合、環境変数経由 API キー、検証済みモデルの所有者専用コピー、エンジン／ガードの SHA-256 マニフェスト、Metal → CPU フォールバック） |
| `Sources/SnapTransOCR` | Apple Vision `RecognizeTextRequest`（高精度モード、自動 / 日本語 / 英語） |
| `Sources/snaptrans-engine-guard` | `llama-server` の親ガードプロセス（アプリ終了・クラッシュ時に `llama-server` を確実に終了） |
| `Sources/SnapTransApp` | AppKit + SwiftUI アプリ本体（メニューバーアイコン、`CGEventTap` 入力、選択枠オーバーレイ、ScreenCaptureKit、結果ポップアップ `NSPanel`、設定画面） |
| `Sources/snaptrans-cli` | 開発用 CLI（ダウンロード・検証・OCR・翻訳・ベンチマーク、起動中アプリへのデバッグコマンド送信） |
| `Packaging/` | `Info.plist`、`engine.entitlements`、配布 ZIP 用 `README-macOS.txt`、`THIRD-PARTY-NOTICES-macOS.header.txt`、`licenses/` |
| `scripts/` | `prepare-engine.sh`（固定版 llama.cpp 取得・照合）、`build-app.sh`（`.app`・ZIP・`.sha256` ビルド）、`make-zip.py`、`check-zip.py`、`install-dev.sh`、`create-dev-cert.sh`、`make-icon.swift` |
| `Tests/SnapTransCoreTests` | コアおよびエンジン整合性のユニットテスト |

### ビルドとテスト

必要なもの: Apple Silicon（arm64）、macOS 15 以降、Xcode 16 以降（Swift 6 ツールチェーン）。

```sh
cd macos
scripts/build-app.sh        # 配布用 → build/MyPLaMo SnapTrans.app, build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip, .zip.sha256
scripts/build-app.sh --dev  # 開発用（テスト用フック入り、ZIP なし）
scripts/install-dev.sh      # → ~/Applications/MyPLaMo SnapTrans.app（開発用の固定配置。--dev のビルドを入れる）
swift test                  # ユニットテストを実行
```

- `build-app.sh` は `prepare-engine.sh` を呼び出し、`ggml-org/llama.cpp` の公式リリース `llama-b12121-bin-macos-arm64.tar.gz` を取得・アーカイブ SHA-256 検証したうえで、`llama-server` と依存する 10 個の dylib を `Contents/Helpers/engine/` に配置し、`Sources/SnapTransEngine/Resources/engine-manifest.json` と照合します（実行時にもアプリが同じ照合を行います）。
- `SNAPTRANS_VERSION` でビルドバージョンを上書きできます（既定は `1.1.0`）。また `SNAPTRANS_ENGINE_CACHE` にアーカイブ格納先を指定すると再ダウンロードを省けます。
- 配布 ZIP には `MyPLaMo-SnapTrans/` 直下に `MyPLaMo SnapTrans.app`、`README.txt`、`LICENSE.txt`、`THIRD-PARTY-NOTICES.txt` を収め、モデル・ログ・ローカルビルドパス・ユーザー名・ホスト名が混入していないことをチェックしたうえで `.zip` と `.zip.sha256` を出力します。ZIP は `scripts/make-zip.py` で作り（`ditto` と違って Unix の UID/GID 拡張フィールドを残さず、時刻は最終コミット時刻に固定）、`scripts/check-zip.py` で ZIP 自体を再走査します。
- 配布ビルドはテスト用フックをコンパイル時に除き（`SNAPTRANS_TEST_HOOKS` 未定義）、ビルドパスを `-file-prefix-map` で置き換え、デバッグ情報を `build/dsym/` に分離してから `strip -S -x` します（dSYM は ZIP に入りません）。
- 第三者ライセンス: `Packaging/licenses/` に llama.cpp b12121 の `vendor/` からエンジンに組み込まれているもの（cpp-httplib、nlohmann/json、xxHash、rotate-bits、SHA-1、SHA-256、stb_image、miniaudio）の表示を置き、`THIRD-PARTY-NOTICES.txt` に連結します。

### 署名（配布用と開発用の 2 経路）

- **配布用（既定）**: ad hoc（`-`）署名＋Hardened Runtime。Developer ID・公証は行いません（v1.1.0 のオーナー決定）。入れ子から順に、エンジンの dylib → `llama-server`（`Packaging/engine.entitlements`）→ ガード → 署名後の最終バイトから実行時マニフェスト（エンジン 11 ファイル＋ガード）をアプリ内に生成 → アプリ本体、の順で署名します。自己署名 `MyPLaMo SnapTrans Dev` は配布用には使えません（指定するとエラー）。任意: `SNAPTRANS_SIGN_IDENTITY="Developer ID Application: …"` を指定するとその ID と secure timestamp で署名します（公証・staple はスクリプト化していません）。
- **Hardened Runtime と entitlements**: ad hoc 署名の dylib には Team ID が無いため、ライブラリ検証で `llama-server` が自分の dylib を読み込めません。`llama-server` にだけ `com.apple.security.cs.disable-library-validation` を付けています（`DYLD_*` 環境変数は引き続き無効、アプリは起動前に全ファイルをマニフェストと照合）。Metal と子プロセス起動（ガード → `llama-server`）に JIT 等の例外は不要でした。
- **開発用（`--dev`）**: テスト用フック入り。ログインキーチェーンに自己署名証明書 `MyPLaMo SnapTrans Dev`（`scripts/create-dev-cert.sh` で初回のみ作成）が存在すればそれを使い、無ければ ad hoc（`-`）で署名します。環境変数 `SNAPTRANS_SIGN_IDENTITY` で明示指定も可能です。署名の順序と Hardened Runtime は配布用と同じです。
- **開発時に自己署名証明書を使う理由**: macOS のプライバシー許可（画面収録・アクセシビリティ）はアプリの Designated Requirement に紐づきます。ad hoc 署名ではビルドごとにコードハッシュが変わるため、**再ビルドのたびに許可が無効化されます**（システム設定上はオンに見えたまま効かなくなることがあります）。自己署名証明書を使うと Designated Requirement が証明書ハッシュで固定されるため、`scripts/install-dev.sh` で固定パスに配置すれば再ビルド後も許可が維持されます。
- **公開配布時の扱い**: Apple の Developer ID 署名・公証（Notarization）を受けていないため、配布時は署名なしアプリ扱いとなります。初回起動時は Gatekeeper にブロックされるため、利用者は「**システム設定**」→「**プライバシーとセキュリティ**」→「**このまま開く**」から開きます。ad hoc 署名ではビルドごとにコード ID が変わるため、更新版をインストールすると許可（画面収録・アクセシビリティ）を付け直す必要があります。

### 許可ダイアログとショートカットの設計メモ

| タイミング | 表示されるダイアログ | 理由・頻度 |
| --- | --- | --- |
| 設定画面「macOS の許可」の「許可を求める」 | アクセシビリティ／画面収録とシステムオーディオ録音 | 署名 ID ごとに初回のみ。画面収録の許可後はアプリ再起動で反映。 |
| 画面収録許可後の初回キャプチャ（ドラッグ／範囲を翻訳／ショートカット） | 「システムプライベートウインドウピッカーをバイパスして画面とオーディオに直接アクセスすることが要求されています」 | macOS 15 以降、Apple のウインドウピッカーを使わず ScreenCaptureKit で直接キャプチャする全アプリに表示されます。macOS 15.1 以降の仕様でおおむね毎月再確認されます（アプリから抑止不可）。「画面の任意の矩形をドラッグ選択する」用途に `SCContentSharingPicker` は合わないため直接キャプチャを採用しています。音声は一切取得しません（`capturesAudio = false`、`captureMicrophone = false`）。 |

- **ショートカット**: 既定は **Control + Shift + ドラッグ**、範囲選択の開始は **Control + Shift + T**。Control + Option は VoiceOver のキーであり、Genspark Speakly のスクリーンアシスタント既定キーとも競合するため避けています。Windows 版の Ctrl + Alt + ドラッグとも重ならないため、Windows から Mac をリモート操作する環境でも併用できます（リモートデスクトップ設定によっては Ctrl が Command に変換される場合があります）。競合時は設定画面の「ショートカット」で変更でき、マウスイベントを横取りする他アプリが存在する場合は設定画面に警告が出ます。
- **保護フォルダー**: 既定では設定・ログ・検証キャッシュ・モデルをすべて `~/Library/Application Support/MyPLaMo-SnapTrans` に保存し、デスクトップ・書類・ダウンロード等の保護フォルダーにはアクセスしません（利用者が明示的にモデル保存先として選んだ場合のみ macOS が一度確認します）。

### 開発・テスト用フック（`--dev` ビルドと `swift build` のデバッグビルドだけ。配布ビルドには含まれません）

- `SNAPTRANS_ENGINE_LOG=1`: `llama-server` の stderr を診断ログに転記（配布ビルドでは stderr はメモリ上で固定の条件だけを検出し、保存しません）

- `SNAPTRANS_PROFILE=<dir>`: 設定・ログ・検証キャッシュの保存先を別フォルダーに変更
- `SNAPTRANS_DEBUG_COMMANDS=1`（または `<suffix>`）: `snaptrans-cli debug <command>` を受付（`DebugCommands.swift` 参照: `select`, `frame`, `interactive`, `idrag`, `status`, `scroll`, `lang`, `theme`, `device`, `model`, `quit` など）
- `SNAPTRANS_ALLOW_MULTIPLE=1`: 多重起動を許可（通常は 2 つ目の起動で既存インスタンスの設定画面を開いて終了）
- `SNAPTRANS_SHOW_IN_CAPTURE=1`: 選択枠をスクリーンショットに写す
- `SNAPTRANS_DEBUG_IMAGE=<png>`: 画面キャプチャの代わりに指定画像を使用
- `SNAPTRANS_ENGINE_DIR` / `SNAPTRANS_GUARD`: CLI から `build/engine` 等を直接指定

権限テスト時はターミナルの権限を継承しないよう LaunchServices 経由で起動してください:

```sh
open -n --env SNAPTRANS_PROFILE=/tmp/snaptrans-test ~/Applications/"MyPLaMo SnapTrans.app"
```

---

## English

### Overview

Developer guide for the macOS version of MyPLaMo SnapTrans (Apple silicon / arm64, menu bar app). For end-user instructions, overview, and license information, see the [Root README](../README.md) (and `README.txt` inside the distribution ZIP).

- Hold **Control + Shift** and drag around text anywhere on screen (or press **Control + Shift + T** / menu **Translate Area**); the area is read with Apple Vision OCR and translated locally by **PLaMo 3 Translate** (`llama.cpp`, Metal / CPU).
- Shares the same model catalog, PFML3 prompt format, download/SHA-256 verification rules, and popup design as the Windows build in `../src`.

### Layout

| Path | What |
| --- | --- |
| `Sources/SnapTransCore` | Model catalog (`Resources/catalog.json`, a copy of `../src/SnapTrans.Core/catalog.json`, checked by a test), download with resume + SHA-256, verification cache, PFML3 prompt, OCR line joining, languages |
| `Sources/SnapTransEngine` | `llama-server` child process (Unix domain socket in an owner-only 0700 folder, per-connection peer PID (`LOCAL_PEERPID`) + start-time check, API key via environment, owner-only copy of the verified model, engine/guard SHA-256 manifest, Metal → CPU fallback) |
| `Sources/SnapTransOCR` | Apple Vision `RecognizeTextRequest` (accurate mode; automatic / Japanese / English) |
| `Sources/snaptrans-engine-guard` | Tiny parent guard for `llama-server` that terminates it whenever the app exits or crashes |
| `Sources/SnapTransApp` | AppKit + SwiftUI app: status item, `CGEventTap` input, overlays, ScreenCaptureKit, result popup (`NSPanel`), Settings |
| `Sources/snaptrans-cli` | Developer tool: download / verify / OCR / translate / benchmark, and debug commands for a running app |
| `Packaging/` | `Info.plist`, `engine.entitlements`, distribution `README-macOS.txt`, `THIRD-PARTY-NOTICES-macOS.header.txt`, `licenses/` |
| `scripts/` | `prepare-engine.sh` (pinned llama.cpp), `build-app.sh` (`.app` + ZIP + `.sha256`), `make-zip.py`, `check-zip.py`, `install-dev.sh`, `create-dev-cert.sh`, `make-icon.swift` |
| `Tests/SnapTransCoreTests` | Unit tests for core and engine integrity |

### Build and Test

Requirements: Apple silicon (arm64), macOS 15+, Xcode 16+ (Swift 6 toolchain).

```sh
cd macos
scripts/build-app.sh        # distribution → build/MyPLaMo SnapTrans.app, build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip, .zip.sha256
scripts/build-app.sh --dev  # development build (test hooks, no ZIP)
scripts/install-dev.sh      # → ~/Applications/MyPLaMo SnapTrans.app (fixed place for development; install a --dev build)
swift test                  # run unit tests
```

- `build-app.sh` invokes `prepare-engine.sh` to download `llama-b12121-bin-macos-arm64.tar.gz` from the official `ggml-org/llama.cpp` release, verifies its archive SHA-256, copies `llama-server` and its 10 linked dylibs into `Contents/Helpers/engine/`, and checks every file against `Sources/SnapTransEngine/Resources/engine-manifest.json` (the same check the app runs before starting the engine).
- Override the build version with `SNAPTRANS_VERSION` (defaults to `1.1.0`), or point `SNAPTRANS_ENGINE_CACHE` at a directory containing the engine archive to skip re-downloading.
- The distribution ZIP contains `MyPLaMo-SnapTrans/{MyPLaMo SnapTrans.app, README.txt, LICENSE.txt, THIRD-PARTY-NOTICES.txt}` and is accompanied by a `.sha256` checksum file after running pre-publish checks (no models, logs, local build paths, user or host names). It is written by `scripts/make-zip.py` (unlike `ditto`, no Unix UID/GID extra fields; timestamps fixed to the last commit) and the ZIP itself is re-scanned by `scripts/check-zip.py`.
- The distribution build compiles out the test hooks (`SNAPTRANS_TEST_HOOKS` undefined), maps build paths with `-file-prefix-map`, splits debug info into `build/dsym/` and then runs `strip -S -x` (dSYMs are not in the ZIP).
- Third-party notices: `Packaging/licenses/` holds the notices of the llama.cpp b12121 `vendor/` code built into the engine (cpp-httplib, nlohmann/json, xxHash, rotate-bits, SHA-1, SHA-256, stb_image, miniaudio); they are appended to `THIRD-PARTY-NOTICES.txt`.

### Signing (distribution and development)

- **Distribution (default)**: ad hoc (`-`) signature + Hardened Runtime; no Developer ID, no notarization (owner's decision for v1.1.0). Inside-out: engine dylibs → `llama-server` (`Packaging/engine.entitlements`) → guard → runtime manifest generated from those final bytes (11 engine files + guard) inside the app → the app. The self-signed `MyPLaMo SnapTrans Dev` identity is refused here. Optional: `SNAPTRANS_SIGN_IDENTITY="Developer ID Application: …"` signs with that identity and a secure timestamp (notarization/stapling is not scripted).
- **Hardened Runtime entitlements**: ad hoc dylibs have no Team ID, so library validation would stop `llama-server` from loading its own dylibs; only `llama-server` gets `com.apple.security.cs.disable-library-validation` (`DYLD_*` variables stay blocked and the app checks every file against the manifest first). Metal and spawning the child (guard → `llama-server`) need no JIT or other exceptions.
- **Development (`--dev`)**: test hooks compiled in; `MyPLaMo SnapTrans Dev` if it exists in the login keychain (create once with `scripts/create-dev-cert.sh`), otherwise ad hoc (`-`). Override with `SNAPTRANS_SIGN_IDENTITY`. Same signing order and Hardened Runtime as the distribution build.
- **Why use a self-signed cert in development**: macOS privacy permissions (Screen Recording, Accessibility) are bound to the app's designated requirement. With ad hoc signing that requirement is the code hash, so **every rebuild invalidates permissions** (even though they may still look enabled in System Settings). With a self-signed certificate the requirement stays pinned to the certificate leaf hash, so permissions survive rebuilds when kept at a fixed path (`scripts/install-dev.sh`).
- **Public distribution**: Not Developer ID signed or notarized, so the app is treated as unsigned/unnotarized. Gatekeeper blocks first launch; users open it via **System Settings → Privacy & Security → Open Anyway**. An ad hoc signature changes with every build, so after installing an update users grant Screen Recording and Accessibility again.

### Permission Prompts and Shortcuts

| When | Dialog | Why / how often |
| --- | --- | --- |
| "Request" in Settings → macOS permissions | Accessibility, Screen & System Audio Recording | Once per signing identity. Granting Screen Recording takes effect after restarting the app. |
| First capture after Screen Recording is granted (Control + Shift drag, Translate Area, shortcut) | "MyPLaMo SnapTrans is requesting to bypass the system private window picker and directly access your screen and audio" | Shown by macOS (15+) for every app that captures directly with ScreenCaptureKit without Apple's window picker. macOS asks again roughly once a month (since macOS 15.1; apps cannot suppress it). `SCContentSharingPicker` does not fit "drag a rectangle anywhere", so SnapTrans uses direct capture. Audio is never captured (`capturesAudio = false`, `captureMicrophone = false`). |

- **Shortcuts**: Default is **Control + Shift + drag**, and **Control + Shift + T** starts area selection. Control + Option is avoided because it is used by VoiceOver and Genspark Speakly's screen assistant. It also avoids overlapping Windows SnapTrans's Ctrl + Alt + drag when controlling a Mac from Windows (note some remote desktop tools remap Ctrl to Command). Users can change shortcuts in Settings → Shortcut, and Settings warns if another app has an active filtering mouse event tap.
- **Protected folders**: Everything defaults to `~/Library/Application Support/MyPLaMo-SnapTrans` (settings, log, verification cache, models); Desktop/Documents/Downloads are never accessed unless explicitly selected as the model folder.

### Testing Hooks (only in `--dev` builds and `swift build` debug builds; compiled out of the distribution build)

- `SNAPTRANS_ENGINE_LOG=1` – copy `llama-server`'s stderr into the diagnostic log (distribution builds only scan it in memory for fixed conditions and never store it).

- `SNAPTRANS_PROFILE=<dir>` – store settings, log, and verification cache in another folder.
- `SNAPTRANS_DEBUG_COMMANDS=1` (or `<suffix>`) – accept `snaptrans-cli debug <command>` (see `DebugCommands.swift`: `select`, `frame`, `interactive`, `idrag`, `status`, `scroll`, `lang`, `theme`, `device`, `model`, `quit`).
- `SNAPTRANS_ALLOW_MULTIPLE=1` – allow a second instance (normally a second launch opens the running instance's Settings and quits).
- `SNAPTRANS_SHOW_IN_CAPTURE=1` – make the selection frame visible to screenshots.
- `SNAPTRANS_DEBUG_IMAGE=<png>` – use an image file instead of capturing the screen.
- `SNAPTRANS_ENGINE_DIR`, `SNAPTRANS_GUARD` – point `snaptrans-cli` at `build/engine`.

Launch via LaunchServices when testing permissions (a binary launched from Terminal inherits Terminal's permissions):

```sh
open -n --env SNAPTRANS_PROFILE=/tmp/snaptrans-test ~/Applications/"MyPLaMo SnapTrans.app"
```
