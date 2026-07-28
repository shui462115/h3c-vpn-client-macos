#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASSETS="$ROOT/GUI/Assets"
BUILD="$ROOT/dist/icon-build"
ICONSET="$BUILD/AppIcon.iconset"
SOURCE="$ASSETS/AppIcon-1024.png"

mkdir -p "$ASSETS" "$ICONSET" "$ROOT/.module-cache"

CLANG_MODULE_CACHE_PATH="$ROOT/.module-cache" swiftc \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    -target arm64-apple-macosx13.0 \
    "$ROOT/GUI/IconGenerator.swift" \
    -framework AppKit \
    -o "$BUILD/icon-generator"

"$BUILD/icon-generator" "$SOURCE"

sips -z 16 16 "$SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$SOURCE" "$ICONSET/icon_512x512@2x.png"

if ! iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"; then
    if [ ! -f "$ASSETS/AppIcon.icns" ]; then
        exit 1
    fi
    echo "warning: iconutil failed; using the existing AppIcon.icns" >&2
fi
