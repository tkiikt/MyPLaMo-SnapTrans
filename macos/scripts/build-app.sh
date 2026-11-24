#!/bin/bash
# Builds "MyPLaMo SnapTrans.app", the distribution ZIP, and its .sha256 file.
#   macos/scripts/build-app.sh          distribution build (default)
#     → macos/build/MyPLaMo SnapTrans.app
#     → macos/build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip
#     → macos/build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip.sha256
#     → macos/build/dsym/*.dSYM         (debug symbols, kept out of the app and the ZIP)
#   macos/scripts/build-app.sh --dev    development build: macos/build/MyPLaMo SnapTrans.app only (no ZIP)
#
# Distribution build: no test hooks (debug commands, image injection, engine/guard overrides, raw engine log and
# profile override are compiled out), build paths mapped out of the binaries, debug info split into dSYMs and stripped,
# every Mach-O signed inside-out with the Hardened Runtime, the engine manifest regenerated from the final signed
# bytes before the app is sealed, and a ZIP without Unix UID/GID fields, scanned for build-machine paths and names.
#   Signature: ad hoc ("-") by default — the owner's decision for v1.1.0: no Developer ID, no notarization, so
#   Gatekeeper blocks the first launch and users open it via System Settings → Privacy & Security → Open Anyway.
#   Optional, unused for v1.1.0: SNAPTRANS_SIGN_IDENTITY="Developer ID Application: …" signs with that identity and a
#   secure timestamp; notarization (xcrun notarytool submit --wait, xcrun stapler staple, then re-create the ZIP) is
#   not automated here. The self-signed "MyPLaMo SnapTrans Dev" identity is refused for distribution.
# Development build (--dev): test hooks compiled in; signed with SNAPTRANS_SIGN_IDENTITY, else "MyPLaMo SnapTrans Dev"
#   when that identity exists (see create-dev-cert.sh), else ad hoc. Ad hoc builds get a new code identity on every
#   build, so macOS privacy permissions granted to an earlier build stop applying (they may still look "on").
#   Install it with install-dev.sh.
#
# Engine: prepare-engine.sh fetches the pinned llama.cpp release and checks it against
# Sources/SnapTransEngine/Resources/engine-manifest.json (the upstream bytes). Both build kinds re-sign the engine with
# the Hardened Runtime (llama-server gets Packaging/engine.entitlements), so the manifest the app checks at run time is
# written into the bundle from the signed files (plus the guard's hash) before the outer signature seals it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
REPO_ROOT=$(cd .. && pwd)
MODE=dist
case "${1:-}" in
  "") ;;
  --dev) MODE=dev ;;
  *) echo "usage: $0 [--dev]" >&2; exit 64 ;;
esac
VERSION=${SNAPTRANS_VERSION:-1.1.0}
BUILD=${SNAPTRANS_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}
APP="$ROOT/build/MyPLaMo SnapTrans.app"
ZIP="$ROOT/build/MyPLaMo-SnapTrans-$VERSION-macos-arm64.zip"
SHA_FILE="$ZIP.sha256"
DSYM="$ROOT/build/dsym"
EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)}

# Signing identity.
IDENTITY=${SNAPTRANS_SIGN_IDENTITY:-}
if [ "$MODE" = dist ]; then
  IDENTITY=${IDENTITY:--}
  case "$IDENTITY" in
    -|"Developer ID Application:"*) ;;
    *) echo "error: distribution builds are signed ad hoc (-) or with a Developer ID Application identity, not \"$IDENTITY\" (use --dev for development builds)" >&2; exit 1 ;;
  esac
else
  if [ -z "$IDENTITY" ]; then
    if security find-identity -v -p codesigning | grep -q '"MyPLaMo SnapTrans Dev"'; then IDENTITY="MyPLaMo SnapTrans Dev"; else IDENTITY="-"; fi
  fi
  [ "$IDENTITY" = "-" ] && echo "warning: ad hoc signature (privacy permissions will not survive a rebuild)" >&2
fi
TIMESTAMP=--timestamp=none
case "$IDENTITY" in "Developer ID Application:"*) TIMESTAMP=--timestamp ;; esac

[ -f build/engine/llama-server ] || scripts/prepare-engine.sh
# The upstream engine files must match the pinned manifest before anything is re-signed.
python3 -I - "$ROOT/build/engine" "$ROOT/Sources/SnapTransEngine/Resources/engine-manifest.json" <<'PY'
import hashlib, json, os, sys
d, m = sys.argv[1], json.load(open(sys.argv[2]))["files"]
for n, sha in m.items():
    if hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() != sha: sys.exit(f"engine file differs from the pinned release: {n}")
PY

# Map local source/home paths out of compiled binaries so release artifacts never contain build machine paths.
SWIFT_FLAGS=(
  -Xswiftc -file-prefix-map -Xswiftc "$REPO_ROOT=/_"
  -Xswiftc -file-prefix-map -Xswiftc "$HOME=/_"
)
[ "$MODE" = dev ] && SWIFT_FLAGS+=(-Xswiftc -DSNAPTRANS_TEST_HOOKS)
swift build -c release --arch arm64 "${SWIFT_FLAGS[@]}" --product SnapTrans
swift build -c release --arch arm64 "${SWIFT_FLAGS[@]}" --product snaptrans-engine-guard
BIN=$(swift build -c release --arch arm64 "${SWIFT_FLAGS[@]}" --show-bin-path)
if [ "$MODE" = dist ] && strings -a "$BIN/SnapTrans" "$BIN/snaptrans-engine-guard" | grep -E 'SNAPTRANS_[A-Z]' >/dev/null; then
  echo "error: test hooks found in the distribution binary (stale build?)" >&2; exit 1
fi

rm -rf "$APP" "$ZIP" "$SHA_FILE" "$DSYM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers/engine" "$APP/Contents/Resources/licenses"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN/SnapTrans" "$APP/Contents/MacOS/SnapTrans"
cp "$BIN/snaptrans-engine-guard" "$APP/Contents/Helpers/snaptrans-engine-guard"
# Debug info: split into dSYMs (outside the app and ZIP), then strip debug and local symbols.
mkdir -p "$DSYM"
dsymutil "$APP/Contents/MacOS/SnapTrans" -o "$DSYM/SnapTrans.dSYM" 2>/dev/null || echo "warning: dsymutil failed for SnapTrans" >&2
dsymutil "$APP/Contents/Helpers/snaptrans-engine-guard" -o "$DSYM/snaptrans-engine-guard.dSYM" 2>/dev/null || echo "warning: dsymutil failed for the guard" >&2
strip -S -x "$APP/Contents/MacOS/SnapTrans" "$APP/Contents/Helpers/snaptrans-engine-guard"
for b in SnapTrans_SnapTransCore SnapTrans_SnapTransEngine; do cp -R "$BIN/$b.bundle" "$APP/Contents/Resources/"; done
cp build/engine/llama-server build/engine/*.dylib "$APP/Contents/Helpers/engine/"
cp build/engine/LICENSE-llama.cpp "$APP/Contents/Resources/licenses/"
cp ../LICENSE "$APP/Contents/Resources/licenses/LICENSE-MyPLaMo-SnapTrans.txt"

# Build THIRD-PARTY-NOTICES.txt (included both in the ZIP root and inside the app bundle).
# Packaging/licenses/: license texts of the third-party code built into the llama.cpp b12121 binaries.
NOTICES="$ROOT/build/THIRD-PARTY-NOTICES.txt"
VENDOR_LICENSES=(
  "boringssl.txt|BoringSSL 0.20261020.0 (libllama-common, libllama-server-impl) - Apache License 2.0"
  "fiat-crypto.txt|fiat-crypto (in BoringSSL 0.20261020.0 third_party/fiat) - Apache License 2.0"
  "cpp-httplib.txt|cpp-httplib v0.64.0 (libllama-common, libllama-server-impl) - MIT License"
  "nlohmann-json.txt|JSON for Modern C++ 3.12.0, nlohmann/json (libllama-common, libllama-server-impl) - MIT License"
  "xxhash.txt|xxHash (libllama-common, libllama-server-impl, libmtmd) - BSD 2-Clause License"
  "rotate-bits.txt|rotate-bits (libllama-common, libllama-server-impl, libmtmd) - MIT License"
  "sha1.txt|SHA-1 (libllama-common, libllama-server-impl, libmtmd) - public domain"
  "sha256.txt|SHA-256 (libllama-common, libllama-server-impl, libmtmd) - public domain"
  "base64-hpp.txt|base64.hpp (libllama-common, libllama-server-impl) - Unlicense (public domain)"
  "llamafile-sgemm.txt|llamafile sgemm (libggml-cpu, Mozilla Foundation) - MIT License"
  "ggml-metal-yarn.txt|YaRN RoPE Metal kernel (libggml-metal, Jeffrey Quesnelle and Bowen Peng) - MIT License"
  "stb_image.txt|stb_image 2.30 (libmtmd) - MIT License or public domain"
  "miniaudio.txt|miniaudio 0.11.26 (libmtmd) - public domain or MIT No Attribution"
  "sheredom-subprocess.txt|sheredom/subprocess.h (libmtmd) - Unlicense (public domain)"
)
{
  sed "s/{VERSION}/$VERSION/g" Packaging/THIRD-PARTY-NOTICES-macOS.header.txt
  printf '\n==============================================================================\n'
  printf 'llama.cpp b12121 (Contents/Helpers/engine/) - MIT License\n'
  printf '==============================================================================\n\n'
  cat build/engine/LICENSE-llama.cpp
  for entry in "${VENDOR_LICENSES[@]}"; do
    printf '\n==============================================================================\n'
    printf '%s\n' "${entry#*|}"
    printf '==============================================================================\n\n'
    cat "Packaging/licenses/${entry%%|*}"
  done
} > "$NOTICES"
cp "$NOTICES" "$APP/Contents/Resources/licenses/THIRD-PARTY-NOTICES.txt"

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift ../assets/icon/app.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Sign inside-out, all with the Hardened Runtime: engine dylibs → llama-server (+ entitlements) → guard → runtime
# manifest of those final bytes → the app (seals Resources, including the manifest, and the nested code).
xattr -cr "$APP"
chmod -R go-w "$APP"
SIGN=(codesign --force --sign "$IDENTITY" "$TIMESTAMP" --options runtime)
for f in "$APP/Contents/Helpers/engine/"*.dylib; do "${SIGN[@]}" "$f"; done
"${SIGN[@]}" --identifier io.github.tkiikt.MyPLaMo-SnapTrans.llama-server --entitlements Packaging/engine.entitlements "$APP/Contents/Helpers/engine/llama-server"
"${SIGN[@]}" --identifier io.github.tkiikt.MyPLaMo-SnapTrans.engine-guard "$APP/Contents/Helpers/snaptrans-engine-guard"
python3 -I - "$APP" "$ROOT/Sources/SnapTransEngine/Resources/engine-manifest.json" <<'PY'
import hashlib, json, os, sys
app, src = sys.argv[1], json.load(open(sys.argv[2]))
eng = os.path.join(app, "Contents/Helpers/engine")
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
assert sorted(os.listdir(eng)) == sorted(src["files"]), "engine folder differs from manifest"
out = {
    "release": src["release"] + "; re-signed by build-app.sh (hashes of the signed files in this app)",
    "files": {n: h(os.path.join(eng, n)) for n in src["files"]},
    "guard": h(os.path.join(app, "Contents/Helpers/snaptrans-engine-guard")),
}
# SwiftPM's resource bundle keeps its files in Contents/Resources (newer build system) or at its root (older one).
bundle = os.path.join(app, "Contents/Resources/SnapTrans_SnapTransEngine.bundle")
dsts = [p for p in (os.path.join(bundle, "Contents/Resources/engine-manifest.json"), os.path.join(bundle, "engine-manifest.json")) if os.path.exists(p)]
assert len(dsts) == 1, f"expected one engine-manifest.json in the resource bundle, found {dsts}"
json.dump(out, open(dsts[0], "w"), indent=1)
PY
"${SIGN[@]}" --identifier io.github.tkiikt.MyPLaMo-SnapTrans "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
echo "Designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

# The engine and guard must still match the bundled runtime manifest after the outer signature.
python3 -I - "$APP" <<'PY'
import hashlib, json, os, sys
app = sys.argv[1]
bundle = os.path.join(app, "Contents/Resources/SnapTrans_SnapTransEngine.bundle")
mp = [p for p in (os.path.join(bundle, "Contents/Resources/engine-manifest.json"), os.path.join(bundle, "engine-manifest.json")) if os.path.exists(p)]
assert len(mp) == 1, mp
m = json.load(open(mp[0]))
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
for n, sha in m["files"].items(): assert h(os.path.join(app, "Contents/Helpers/engine", n)) == sha, n
assert h(os.path.join(app, "Contents/Helpers/snaptrans-engine-guard")) == m["guard"], "guard"
PY

if [ "$MODE" = dev ]; then
  echo "App (development build, test hooks on): $APP"
  echo "Install with scripts/install-dev.sh"
  exit 0
fi

# ZIP layout: MyPLaMo-SnapTrans/{MyPLaMo SnapTrans.app, README.txt, LICENSE.txt, THIRD-PARTY-NOTICES.txt}
STAGE="$ROOT/build/zip/MyPLaMo-SnapTrans"
rm -rf "$ROOT/build/zip"; mkdir -p "$STAGE"
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/MyPLaMo SnapTrans.app"
sed "s/{VERSION}/$VERSION/g" Packaging/README-macOS.txt > "$STAGE/README.txt"
cp ../LICENSE "$STAGE/LICENSE.txt"
cp "$NOTICES" "$STAGE/THIRD-PARTY-NOTICES.txt"
chmod 644 "$STAGE/README.txt" "$STAGE/LICENSE.txt" "$STAGE/THIRD-PARTY-NOTICES.txt"

# Pre-publish checks: no models, logs, settings, debug symbols, or build-machine paths/names in the staged package.
GIT_EMAIL=$(git -C "$REPO_ROOT" config user.email 2>/dev/null || true)
NEEDLES=()
for n in "/Users/${USER:-}" "Users/${USER:-}" "$HOME" "$REPO_ROOT" "$(dirname "$REPO_ROOT")" "${USER:-}" "$(id -un)" \
         "$(hostname -s 2>/dev/null)" "$(scutil --get LocalHostName 2>/dev/null)" "$(scutil --get ComputerName 2>/dev/null)"; do
  [ ${#n} -ge 4 ] && NEEDLES+=("$n")
done
case "$GIT_EMAIL" in *noreply.github.com*|"") ;; *) NEEDLES+=("$GIT_EMAIL") ;; esac
python3 -I - "$STAGE" "${NEEDLES[@]}" <<'PY'
import os, sys
stage, needles = sys.argv[1], sorted(set(sys.argv[2:]))
bad_exts = (".gguf", ".bin", ".safetensors", ".pdb", ".log", ".traineddata")
bad_names = {"settings.json", "verify-cache.json", ".DS_Store"}
hits = []
file_count = 0
for root_dir, dirs, files in os.walk(stage):
    for d in dirs:
        if d.endswith(".dSYM"):
            hits.append(f"unexpected dir: {os.path.relpath(os.path.join(root_dir, d), stage)}")
    for fn in files:
        p = os.path.join(root_dir, fn)
        rel = os.path.relpath(p, stage)
        file_count += 1
        if fn in bad_names or fn.lower().endswith(bad_exts):
            hits.append(f"unexpected file: {rel}")
            continue
        lower = open(p, "rb").read().lower()
        for n in needles:
            if n.lower().encode("utf-8") in lower:
                hits.append(f"{rel}: contains a build-machine name or path")
if hits:
    sys.stderr.write("pre-publish check failed:\n" + "\n".join(hits) + "\n")
    sys.exit(1)
print(f"Pre-publish checks passed ({file_count} files, {len(needles)} patterns)")
PY

# ZIP without Unix UID/GID extra fields (ditto -c -k stores them), fixed timestamps; then check the ZIP itself.
python3 -I scripts/make-zip.py "$STAGE" "$ZIP" "$EPOCH"
python3 -I scripts/check-zip.py "$ZIP" "${NEEDLES[@]}"
HASH=$(shasum -a 256 "$ZIP" | awk '{print $1}')
printf '%s  %s\n' "$HASH" "$(basename "$ZIP")" > "$SHA_FILE"
echo "App: $APP"
echo "ZIP: $ZIP ($(stat -f %z "$ZIP") bytes, $(du -h "$ZIP" | cut -f1))"
echo "SHA256: $HASH  $(basename "$ZIP")"
