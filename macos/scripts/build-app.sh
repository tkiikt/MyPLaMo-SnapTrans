#!/bin/bash
# Builds "MyPLaMo SnapTrans.app", the distribution ZIP, and its .sha256 file.
#   macos/scripts/build-app.sh
#     → macos/build/MyPLaMo SnapTrans.app
#     → macos/build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip
#     → macos/build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip.sha256
# Steps: swift build (release, arm64, prefix-mapped) → pinned llama.cpp engine (prepare-engine.sh, SHA-256 checked) →
# bundle layout → icon from assets/icon/app.svg → strip → codesign → pre-publish checks → ditto ZIP → SHA-256.
# Signing: SNAPTRANS_SIGN_IDENTITY, else "MyPLaMo SnapTrans Dev" when that identity exists (see create-dev-cert.sh),
# else ad hoc ("-"). Ad hoc builds get a new code identity on every build, so macOS privacy permissions granted to an
# earlier build stop applying (they may still look "on" in System Settings).
# The engine files keep the llama.cpp release's own (linker ad hoc) signatures: their SHA-256 is what the app checks
# against engine-manifest.json at run time. Re-signing them (e.g. Developer ID + hardened runtime) changes those
# hashes, so a signed release must regenerate the manifest from the signed files.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
REPO_ROOT=$(cd .. && pwd)
VERSION=${SNAPTRANS_VERSION:-1.1.0}
BUILD=${SNAPTRANS_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}
APP="$ROOT/build/MyPLaMo SnapTrans.app"
ZIP="$ROOT/build/MyPLaMo-SnapTrans-$VERSION-macos-arm64.zip"
SHA_FILE="$ZIP.sha256"

[ -f build/engine/llama-server ] || scripts/prepare-engine.sh

# Map local source/home paths out of compiled binaries so release artifacts never contain build machine paths.
SWIFT_FLAGS=(
  -Xswiftc -file-prefix-map -Xswiftc "$REPO_ROOT=/_"
  -Xswiftc -file-prefix-map -Xswiftc "$HOME=/_"
)
swift build -c release --arch arm64 "${SWIFT_FLAGS[@]}" --product SnapTrans
swift build -c release --arch arm64 "${SWIFT_FLAGS[@]}" --product snaptrans-engine-guard
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP" "$ZIP" "$SHA_FILE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers/engine" "$APP/Contents/Resources/licenses"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN/SnapTrans" "$APP/Contents/MacOS/SnapTrans"
cp "$BIN/snaptrans-engine-guard" "$APP/Contents/Helpers/snaptrans-engine-guard"
strip -x "$APP/Contents/MacOS/SnapTrans" "$APP/Contents/Helpers/snaptrans-engine-guard"
for b in SnapTrans_SnapTransCore SnapTrans_SnapTransEngine; do cp -R "$BIN/$b.bundle" "$APP/Contents/Resources/"; done
cp build/engine/llama-server build/engine/*.dylib "$APP/Contents/Helpers/engine/"
cp build/engine/LICENSE-llama.cpp "$APP/Contents/Resources/licenses/"
cp ../LICENSE "$APP/Contents/Resources/licenses/LICENSE-MyPLaMo-SnapTrans.txt"

# Build THIRD-PARTY-NOTICES.txt (included both in the ZIP root and inside the app bundle).
NOTICES="$ROOT/build/THIRD-PARTY-NOTICES.txt"
{
  sed "s/{VERSION}/$VERSION/g" Packaging/THIRD-PARTY-NOTICES-macOS.header.txt
  printf '\n==============================================================================\n'
  printf 'llama.cpp b12121 (Contents/Helpers/engine/) - MIT License\n'
  printf '==============================================================================\n\n'
  cat build/engine/LICENSE-llama.cpp
} > "$NOTICES"
cp "$NOTICES" "$APP/Contents/Resources/licenses/THIRD-PARTY-NOTICES.txt"

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift ../assets/icon/app.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=${SNAPTRANS_SIGN_IDENTITY:-}
if [ -z "$IDENTITY" ]; then
  if security find-identity -v -p codesigning | grep -q '"MyPLaMo SnapTrans Dev"'; then IDENTITY="MyPLaMo SnapTrans Dev"; else IDENTITY="-"; fi
fi
[ "$IDENTITY" = "-" ] && echo "warning: ad hoc signature (privacy permissions will not survive a rebuild)" >&2
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier io.github.tkiikt.MyPLaMo-SnapTrans.engine-guard "$APP/Contents/Helpers/snaptrans-engine-guard"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier io.github.tkiikt.MyPLaMo-SnapTrans "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

# The engine must still match the manifest after signing.
python3 - "$APP/Contents/Helpers/engine" <<'PY'
import hashlib, json, os, sys
m = json.load(open("Sources/SnapTransEngine/Resources/engine-manifest.json"))["files"]
d = sys.argv[1]
assert sorted(os.listdir(d)) == sorted(m), "engine folder differs from manifest"
for n, sha in m.items():
    assert hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() == sha, n
PY

# ZIP layout: MyPLaMo-SnapTrans/{MyPLaMo SnapTrans.app, README.txt, LICENSE.txt, THIRD-PARTY-NOTICES.txt}
STAGE="$ROOT/build/zip/MyPLaMo-SnapTrans"
rm -rf "$ROOT/build/zip"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MyPLaMo SnapTrans.app"
sed "s/{VERSION}/$VERSION/g" Packaging/README-macOS.txt > "$STAGE/README.txt"
cp ../LICENSE "$STAGE/LICENSE.txt"
cp "$NOTICES" "$STAGE/THIRD-PARTY-NOTICES.txt"

# Pre-publish checks: no models, logs, settings, debug symbols, or build-machine paths in the staged package.
GIT_EMAIL=$(git -C "$REPO_ROOT" config user.email 2>/dev/null || true)
python3 - "$STAGE" "$HOME" "$REPO_ROOT" "${USER:-}" "$GIT_EMAIL" <<'PY'
import os, sys
stage, home, repo_root, user, git_email = sys.argv[1:6]
bad_exts = (".gguf", ".bin", ".safetensors", ".pdb", ".log", ".traineddata")
bad_names = {"settings.json", "verify-cache.json", ".DS_Store"}
needles = []
for n in [f"/Users/{user}" if user else "", f"Users/{user}" if user else "", home, repo_root, os.path.dirname(repo_root)]:
    if n and len(n) >= 4 and n not in needles:
        needles.append(n)
if git_email and "noreply.github.com" not in git_email.lower():
    needles.append(git_email)

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
        data = open(p, "rb").read()
        lower = data.lower()
        for n in needles:
            if n.lower().encode("utf-8") in lower:
                hits.append(f"{rel}: contains '{n}'")
if hits:
    sys.stderr.write("pre-publish check failed:\n" + "\n".join(hits) + "\n")
    sys.exit(1)
print(f"Pre-publish checks passed ({file_count} files, {len(needles)} patterns)")
PY

(cd "$ROOT/build/zip" && ditto -c -k --norsrc --noextattr --keepParent MyPLaMo-SnapTrans "$ZIP")
HASH=$(shasum -a 256 "$ZIP" | awk '{print $1}')
printf '%s  %s\n' "$HASH" "$(basename "$ZIP")" > "$SHA_FILE"
echo "App: $APP"
echo "ZIP: $ZIP ($(stat -f %z "$ZIP") bytes, $(du -h "$ZIP" | cut -f1))"
echo "SHA256: $HASH  $(basename "$ZIP")"
