#!/bin/bash
# Fetch the prebuilt whisper.cpp xcframework into .deps/ (required to build).
set -euo pipefail

VERSION="v1.9.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.deps"

if [[ -d "$DEST/build-apple/whisper.xcframework" ]]; then
    echo "already present: $DEST/build-apple/whisper.xcframework"
    exit 0
fi

mkdir -p "$DEST"
echo "downloading whisper $VERSION xcframework…"
curl -sL -o "$DEST/whisper-xcframework.zip" \
    "https://github.com/ggml-org/whisper.cpp/releases/download/$VERSION/whisper-$VERSION-xcframework.zip"
unzip -qo "$DEST/whisper-xcframework.zip" -d "$DEST"
echo "ready: $DEST/build-apple/whisper.xcframework"
