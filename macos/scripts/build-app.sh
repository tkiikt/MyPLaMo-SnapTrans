#!/bin/bash
# Builds "MyPLaMo SnapTrans.app" (ad hoc signed) and a ZIP for distribution outside the App Store.
#   macos/scripts/build-app.sh            → macos/build/MyPLaMo SnapTrans.app, macos/build/MyPLaMo-SnapTrans-<ver>-macos-arm64.zip
# Steps: swift build (release, arm64) → pinned llama.cpp engine (prepare-engine.sh, SHA-256 checked) → bundle layout →
# icon from assets/icon/app.svg → ad hoc codesign → ditto ZIP.
# Signing: SNAPTRANS_SIGN_IDENTITY, else "MyPLaMo SnapTrans Dev" when that identity exists (see create-dev-cert.sh),
# else ad hoc ("-"). Ad hoc builds get a new code identity on every build, so macOS privacy permissions granted to an
# earlier build stop applying (they may still look "on" in System Settings).
# The engine files keep the llama.cpp release's own (linker ad hoc) signatures: their SHA-256 is what the app checks
# against engine-manifest.json at run time. Re-signing them (e.g. Developer ID + hardened runtime) changes those
# hashes, so a signed release must regenerate the manifest from the signed files.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=${SNAPTRANS_VERSION:-1.0.0}
BUILD=${SNAPTRANS_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}
APP="$ROOT/build/MyPLaMo SnapTrans.app"
ZIP="$ROOT/build/MyPLaMo-SnapTrans-$VERSION-macos-arm64.zip"

[ -f build/engine/llama-server ] || scripts/prepare-engine.sh
swift build -c release --arch arm64 --product SnapTrans
swift build -c release --arch arm64 --product snaptrans-engine-guard
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers/engine" "$APP/Contents/Resources/licenses"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN/SnapTrans" "$APP/Contents/MacOS/SnapTrans"
cp "$BIN/snaptrans-engine-guard" "$APP/Contents/Helpers/snaptrans-engine-guard"
for b in SnapTrans_SnapTransCore SnapTrans_SnapTransEngine; do cp -R "$BIN/$b.bundle" "$APP/Contents/Resources/"; done
cp build/engine/llama-server build/engine/*.dylib "$APP/Contents/Helpers/engine/"
cp build/engine/LICENSE-llama.cpp "$APP/Contents/Resources/licenses/"
cp ../LICENSE "$APP/Contents/Resources/licenses/LICENSE-MyPLaMo-SnapTrans.txt"

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
# ZIP layout: MyPLaMo-SnapTrans/{MyPLaMo SnapTrans.app, README.txt}
STAGE="$ROOT/build/zip/MyPLaMo-SnapTrans"
rm -rf "$ROOT/build/zip"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MyPLaMo SnapTrans.app"
sed "s/{VERSION}/$VERSION/" Packaging/README-macOS.txt > "$STAGE/README.txt"
(cd "$ROOT/build/zip" && ditto -c -k --norsrc --noextattr --keepParent MyPLaMo-SnapTrans "$ZIP")
echo "App: $APP"
echo "ZIP: $ZIP ($(du -h "$ZIP" | cut -f1))"
