#!/bin/bash
# Assemble and sign autowhisper.app from the SwiftPM release build.
# Usage: Scripts/make-app.sh [product]   (default: autowhisper)
set -euo pipefail

PRODUCT="${1:-autowhisper}"
[[ "$PRODUCT" == "--install" ]] && PRODUCT=autowhisper
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/$PRODUCT"
APP="$ROOT/dist/$PRODUCT.app"
BUNDLE_ID="com.coverston.$PRODUCT"

swift build -c release --package-path "$ROOT" --product "$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
ICON_LINE=""
if [[ -f "$ROOT/Resources/autowhisper.icns" ]]; then
    cp "$ROOT/Resources/autowhisper.icns" "$APP/Contents/Resources/autowhisper.icns"
    ICON_LINE="<key>CFBundleIconFile</key><string>autowhisper</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$PRODUCT</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    $ICON_LINE
    <key>NSMicrophoneUsageDescription</key>
    <string>autowhisper records the microphone to transcribe your sessions.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>autowhisper records system audio to transcribe your sessions.</string>
</dict>
</plist>
PLIST

# Embed whisper.framework when the binary links it.
FRAMEWORKS="$APP/Contents/Frameworks"
if otool -L "$BIN" | grep -q "whisper.framework"; then
    mkdir -p "$FRAMEWORKS"
    cp -R "$ROOT/.deps/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework" "$FRAMEWORKS/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null || true
fi

# Embedded frameworks must be signed before the outer bundle.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
SIGN=("--force" "--sign" "${IDENTITY:--}")
if [[ -d "$FRAMEWORKS" ]]; then
    find "$FRAMEWORKS" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) \
        -exec codesign "${SIGN[@]}" {} \;
fi
codesign "${SIGN[@]}" "$APP"

echo "built: $APP (signed: ${IDENTITY:-ad-hoc})"

# --install: copy to /Applications (replacing any previous install)
if [[ "${2:-}" == "--install" || "${1:-}" == "--install" ]]; then
    pkill -x "$PRODUCT" 2>/dev/null || true
    ditto "$APP" "/Applications/$PRODUCT.app"
    echo "installed: /Applications/$PRODUCT.app"
fi
