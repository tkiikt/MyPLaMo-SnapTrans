# MyPLaMo SnapTrans (Windows) — 開発者向けビルド手順 / Developer Build Guide

[日本語](#日本語) | [English](#english)

アプリの概要・使い方・配布物のインストール方法はルートの [README.md](../README.md) を参照してください。
For an overview, usage, and installation instructions, see the root [README.md](../README.md).

---

## 日本語

### 必要なもの

- Windows 10 / 11 (x64)
- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- PowerShell 7 (`pwsh`)
- Visual Studio 2022 以降の「C++ によるデスクトップ開発」（ランチャーの Native AOT ビルドと VC++ ランタイムの同梱に使用）

### ビルド手順

リポジトリルートで以下を実行します。

```powershell
# 配布用 ZIP（dist\MyPLaMo-SnapTrans-<version>-win-x64.zip と .sha256）
pwsh -File packaging\package.ps1                 # バージョンは Directory.Build.props
pwsh -File packaging\package.ps1 -Version 1.1.0

# 開発用（ランチャーなしの発行フォルダー release\MyPLaMo-SnapTrans\）
pwsh -File build.ps1
```

- `scripts/Prepare-Engine.ps1` が llama.cpp b12121（Vulkan 版）を取得・SHA-256 を照合し、`engine/cpu` と `engine/vulkan` を作ります（`package.ps1` と `build.ps1` が自動で呼びます）。
- `package.ps1` は、モデル・PDB・ログ・設定ファイルが入っていないこと、ビルドした PC のユーザー名やパスが含まれていないことを確認してから ZIP を作ります。
- アイコンは `assets/icon/*.svg` から `scripts/Make-Icon.ps1` で `src/SnapTrans.App/Assets/` に書き出します（`-Check` でコミット済みのものと同じか確認）。

### 構成

```text
src/
  SnapTrans.Core           OCR / 翻訳のインターフェース、PFML3 プロンプト、モデルカタログとダウンロード（再開・SHA-256）
  SnapTrans.Llama          llama-server 子プロセス（127.0.0.1・ランダムポート・API キー・ジョブオブジェクト）、GPU 列挙、CUDA エンジン導入
  SnapTrans.Ocr.Windows    Windows.Media.Ocr 実装
  SnapTrans.Ocr.Tesseract  Tesseract 5 実装（任意）
  SnapTrans.App            WinUI 3 アプリ（トレイ、設定、ポップアップ、選択枠）
  SnapTrans.Launcher       配布 ZIP 最上位の起動用 exe（Native AOT）
tools/SnapTrans.Bench      モデル取得・GPU 列挙・OCR 比較・翻訳時間計測の CLI
packaging/                 package.ps1、README.txt、THIRD-PARTY-NOTICES の元
```

### 開発・検証用の環境変数

| 変数 | 用途 |
| --- | --- |
| `SNAPTRANS_PROFILE` | 設定・ログ・CUDA エンジン・tessdata の場所を変更 |
| `SNAPTRANS_SHOW_IN_CAPTURE=1` | 選択中の枠をスクリーンショットに写す（説明用） |
| `SNAPTRANS_DEBUG_LOAD_DELAY_MS` | モデル読み込みの最初に待ちを入れる（切替・終了中の表示の確認用） |
| `SNAPTRANS_DEBUG_FIRST_PORT` | 最初の起動だけ指定ポートを使う（ポート競合からの再試行の確認用） |
| `SNAPTRANS_DEBUG_FAIL_HOOK=mouse\|keyboard\|both` | 入力フックの設置失敗を再現する |
| `SNAPTRANS_DEBUG_TRAY_THEME_FILE` | タスクバーのテーマをファイル（`light` / `dark`）から読む |
| `SNAPTRANS_DEBUG_NO_LAUNCH=1` | ライセンスのリンクを押してもブラウザーを開かず、開く URL をログに書く（GUI テスト用） |

---

## English

### Requirements

- Windows 10 / 11 (x64)
- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- PowerShell 7 (`pwsh`)
- Visual Studio 2022 or later with "Desktop development with C++" (used for the Native AOT launcher and the bundled VC++ runtime)

### Build commands

Run the following from the repository root:

```powershell
# Distribution ZIP (dist\MyPLaMo-SnapTrans-<version>-win-x64.zip and .sha256)
pwsh -File packaging\package.ps1                 # version from Directory.Build.props
pwsh -File packaging\package.ps1 -Version 1.1.0

# Development build without the launcher (release\MyPLaMo-SnapTrans\)
pwsh -File build.ps1
```

- `scripts/Prepare-Engine.ps1` downloads llama.cpp b12121 (Vulkan build), verifies its SHA-256, and lays out `engine/cpu` and `engine/vulkan` (called automatically by `package.ps1` and `build.ps1`).
- Before zipping, `package.ps1` checks that no model, PDB, log, or settings file is included and that no user name or local path of the build PC appears in any file.
- Icons are generated from `assets/icon/*.svg` into `src/SnapTrans.App/Assets/` by `scripts/Make-Icon.ps1` (`-Check` compares with the committed files).

### Project layout

```text
src/
  SnapTrans.Core           OCR / translation interfaces, PFML3 prompts, model catalog and downloads (resume, SHA-256)
  SnapTrans.Llama          llama-server child process (127.0.0.1, random port, API key, job object), GPU enumeration, CUDA engine installer
  SnapTrans.Ocr.Windows    Windows.Media.Ocr implementation
  SnapTrans.Ocr.Tesseract  Tesseract 5 implementation (optional)
  SnapTrans.App            WinUI 3 app (tray, settings, popup, selection overlay)
  SnapTrans.Launcher       Top-level launcher exe in the distribution ZIP (Native AOT)
tools/SnapTrans.Bench      CLI for model download, GPU enumeration, OCR comparison, and translation benchmarks
packaging/                 package.ps1, README.txt, and THIRD-PARTY-NOTICES sources
```

### Developer and verification environment variables

| Variable | Purpose |
| --- | --- |
| `SNAPTRANS_PROFILE` | Override the directory for settings, logs, CUDA engine, and tessdata |
| `SNAPTRANS_SHOW_IN_CAPTURE=1` | Allow the selection overlay to appear in screenshots (for documentation) |
| `SNAPTRANS_DEBUG_LOAD_DELAY_MS` | Add an initial delay before loading a model (for testing switching / exiting states) |
| `SNAPTRANS_DEBUG_FIRST_PORT` | Use a specific port on the first launch only (for testing port-conflict retry) |
| `SNAPTRANS_DEBUG_FAIL_HOOK=mouse\|keyboard\|both` | Simulate input hook installation failure |
| `SNAPTRANS_DEBUG_TRAY_THEME_FILE` | Read taskbar theme (`light` / `dark`) from a file |
| `SNAPTRANS_DEBUG_NO_LAUNCH=1` | Log the target URL instead of opening a browser when clicking a license link (for GUI testing) |
