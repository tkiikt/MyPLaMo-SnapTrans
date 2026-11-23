#!/bin/bash
# Downloads the pinned llama.cpp release for macOS arm64, verifies the archive SHA-256, and lays out
# build/engine (llama-server + the dylibs it links, as regular files under the names it loads), then checks every
# file against Sources/SnapTransEngine/Resources/engine-manifest.json (the same hashes the app checks at run time).
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b12121
NAME="llama-$TAG-bin-macos-arm64.tar.gz"
SHA=75e2176148b2d79ff20f503fa131f3d66d74176ed06c58f48e273e20383c32c2
DL=build/downloads
mkdir -p "$DL"
if [ ! -f "$DL/$NAME" ]; then
  if [ -n "${SNAPTRANS_ENGINE_CACHE:-}" ] && [ -f "$SNAPTRANS_ENGINE_CACHE/$NAME" ]; then cp "$SNAPTRANS_ENGINE_CACHE/$NAME" "$DL/$NAME"
  else curl -fLsS --retry 3 -o "$DL/$NAME.part" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$NAME" && mv "$DL/$NAME.part" "$DL/$NAME"; fi
fi
echo "$SHA  $DL/$NAME" | shasum -a 256 -c - >/dev/null || { echo "Unexpected engine archive hash: $NAME" >&2; exit 1; }
STAGE=build/engine-staging
rm -rf "$STAGE" build/engine
mkdir -p "$STAGE" build/engine
tar -xzf "$DL/$NAME" -C "$STAGE"
SRC="$STAGE/llama-$TAG"
for f in llama-server libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib libllama.0.dylib libggml.0.dylib \
         libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib libggml-rpc.0.dylib libggml-base.0.dylib; do
  cp -L "$SRC/$f" "build/engine/$f"     # -L: the archive ships versioned files behind symlinks
done
cp "$SRC/LICENSE" build/engine/LICENSE-llama.cpp
xattr -cr build/engine
python3 - <<'PY'
import hashlib, json, os, sys
m = json.load(open("Sources/SnapTransEngine/Resources/engine-manifest.json"))["files"]
for name, sha in m.items():
    h = hashlib.sha256(open(os.path.join("build/engine", name), "rb").read()).hexdigest()
    if h != sha: sys.exit(f"manifest mismatch: {name}")
PY
echo "Prepared llama.cpp $TAG (macOS arm64, Metal/CPU) in $(pwd)/build/engine"
