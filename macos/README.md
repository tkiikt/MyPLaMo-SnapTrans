# MyPLaMo SnapTrans for macOS

Menu bar version of MyPLaMo SnapTrans: hold **Control + Option** and drag around text anywhere on screen; the area is
read with Apple Vision and translated locally by PLaMo 3 Translate (llama.cpp). Same models, catalog, prompt format,
download/verification rules and popup design as the Windows build in `../src`.

Built with PLaMo. Unofficial; not provided, endorsed, or affiliated with Preferred Networks, Inc.

## Layout

| Path | What |
| --- | --- |
| `Sources/SnapTransCore` | Model catalog (`Resources/catalog.json`, a copy of `../src/SnapTrans.Core/catalog.json`, checked by a test), download with resume + SHA-256, verification cache, PFML3 prompt, OCR line joining, languages |
| `Sources/SnapTransEngine` | llama-server child: 127.0.0.1, random port, API key via environment, listener PID + executable check (libproc), engine SHA-256 manifest, Metal → CPU fallback |
| `Sources/SnapTransOCR` | Vision `RecognizeTextRequest` (accurate; automatic / Japanese / English) |
| `Sources/snaptrans-engine-guard` | Tiny parent for llama-server: kills it when the app exits or crashes |
| `Sources/SnapTransApp` | AppKit + SwiftUI app: status item, CGEventTap input, overlays, ScreenCaptureKit, popup (NSPanel), Settings |
| `Sources/snaptrans-cli` | Developer tool: download / verify / OCR / translate / benchmark, and test commands for a running app |
| `scripts/` | `prepare-engine.sh` (pinned llama.cpp), `build-app.sh` (.app + ZIP), `install-dev.sh`, `create-dev-cert.sh`, `make-icon.swift` |

## Build

Requirements: Apple silicon, macOS 15+, Xcode 16+ (Swift 6 toolchain).

```sh
cd macos
scripts/build-app.sh        # → build/MyPLaMo SnapTrans.app and build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip
scripts/install-dev.sh      # → ~/Applications/MyPLaMo SnapTrans.app (fixed place for development)
swift test                  # unit tests
```

`build-app.sh` downloads `llama-b12121-bin-macos-arm64.tar.gz` from the ggml-org/llama.cpp release, checks its SHA-256,
copies `llama-server` and the 10 dylibs it links into `Contents/Helpers/engine` and checks each against
`Sources/SnapTransEngine/Resources/engine-manifest.json` (the same check the app runs before starting the engine).

### Signing

* Default identity: `MyPLaMo SnapTrans Dev` if it exists in the keychain (create it once with
  `scripts/create-dev-cert.sh`), otherwise ad hoc. Override with `SNAPTRANS_SIGN_IDENTITY`.
* macOS privacy permissions (Screen Recording, Accessibility) belong to the app's designated requirement. With ad hoc
  signing that is the code hash, so **every rebuild loses the permissions** (they can still look enabled in System
  Settings). With a certificate the requirement is `identifier "io.github.tkiikt.MyPLaMo-SnapTrans" and certificate leaf
  = H"…"`, which survives rebuilds; keep the app at one place (`install-dev.sh`).
* For public distribution: Developer ID + notarization (paid Apple Developer Program). Re-signing the engine files
  changes their hashes, so regenerate `engine-manifest.json` from the signed files in that case. An unnotarized ZIP is
  blocked by Gatekeeper on first launch (System Settings → Privacy & Security → "Open Anyway").

## Permission prompts users will see

| When | Dialog | Why / how often |
| --- | --- | --- |
| "Request" in Settings → macOS permissions | Accessibility, Screen & System Audio Recording | Once per signing identity. Granting Screen Recording takes effect after the app restarts. |
| First capture after Screen Recording was granted (any path: Control + Option drag, Translate Area, shortcut) | "MyPLaMo SnapTrans is requesting to bypass the system private window picker and directly access your screen and audio" | Shown by macOS (15+) for every app that captures with ScreenCaptureKit without Apple's window picker. macOS asks again periodically (about monthly since macOS 15.1, as Apple has decided; an app cannot suppress it). The picker (SCContentSharingPicker) does not fit "drag a rectangle anywhere", so SnapTrans keeps direct capture. Audio is never captured (`capturesAudio = false`, `captureMicrophone = false`); the wording about audio is fixed by macOS. |

SnapTrans does not read or write Desktop, Documents, Downloads or other protected folders: by default everything is in
`~/Library/Application Support/MyPLaMo-SnapTrans` (settings, log, verification cache, models). A folder prompt appears
only if the user picks such a folder as the model folder (macOS then asks once for that folder).

## Testing hooks (never active in normal use)

* `SNAPTRANS_PROFILE=<dir>` – settings, log and verification cache in another folder.
* `SNAPTRANS_DEBUG_COMMANDS=1` – accept `snaptrans-cli debug <command>` (see `DebugCommands.swift`): `select x y w h`,
  `frame …`, `interactive`, `idrag …`, `scroll <section>`, `lang`, `theme`, `device`, `model`, `quit`.
* `SNAPTRANS_SHOW_IN_CAPTURE=1` – make the selection frame visible to screenshots.
* `SNAPTRANS_DEBUG_IMAGE=<png>` – use an image instead of the screen.
* `SNAPTRANS_ENGINE_DIR`, `SNAPTRANS_GUARD` – run the CLI against `build/engine`.

Launch through LaunchServices to test permissions (a binary started from a terminal inherits the terminal's
permissions): `open -n --env SNAPTRANS_PROFILE=… ~/Applications/"MyPLaMo SnapTrans.app"`.
