#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLI="$ROOT/dist/H3CVPN-macos-arm64"
BUILD="$ROOT/dist/gui-build"
APP="$BUILD/SSL VPN Connect.app"
STAGE="$ROOT/dist/dmg-stage"
OUTPUT=${1:-"$ROOT/dist/SSLVPNConnect-macOS-arm64.dmg"}

if [ ! -x "$CLI/Resources/openconnect" ]; then
    "$ROOT/scripts/build.sh"
fi

rm -rf "$BUILD" "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE"
mkdir -p "$ROOT/.module-cache"
mkdir -p "$ROOT/dist/helper-build"

"$ROOT/scripts/build-icon.sh"

clang -O2 -Wall -Wextra -Wpedantic \
    "$ROOT/Helper/h3cvpn-helper.c" \
    -o "$ROOT/dist/helper-build/com.codex.h3cvpn.helper"

CLANG_MODULE_CACHE_PATH="$ROOT/.module-cache" swiftc \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    -target arm64-apple-macosx13.0 \
    -O -parse-as-library \
    "$ROOT/GUI/H3CVPNApp.swift" "$ROOT/GUI/H3CVPNUpdate.swift" \
    -framework SwiftUI -framework AppKit \
    -o "$APP/Contents/MacOS/H3CVPN"

CLANG_MODULE_CACHE_PATH="$ROOT/.module-cache" swiftc \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    -target arm64-apple-macosx13.0 \
    -O \
    "$ROOT/GUI/H3CVPNUpdater.swift" \
    -o "$APP/Contents/Resources/H3CVPNUpdater"

cp "$ROOT/GUI/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/GUI/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$CLI/Resources/"* "$APP/Contents/Resources/"
cp "$ROOT/dist/helper-build/com.codex.h3cvpn.helper" "$APP/Contents/Resources/com.codex.h3cvpn.helper"
cp "$ROOT/Helper/com.codex.h3cvpn.helper.plist" "$APP/Contents/Resources/com.codex.h3cvpn.helper.plist"
cp "$ROOT/README.md" "$APP/Contents/Resources/README.md"
cp "$ROOT/TEST-REPORT.md" "$APP/Contents/Resources/TEST-REPORT.md"
cp "$CLI/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$CLI/Licenses" "$APP/Contents/Resources/Licenses"
chmod 755 "$APP/Contents/MacOS/H3CVPN" "$APP/Contents/Resources/H3CVPNUpdater"
chmod 755 "$APP/Contents/Resources/openconnect" "$APP/Contents/Resources/vpnc-script"
chmod 755 "$APP/Contents/Resources/com.codex.h3cvpn.helper"

for item in "$APP/Contents/Resources/"*.dylib; do
    codesign --force --sign - "$item"
done
codesign --force --sign - "$APP/Contents/Resources/openconnect"
codesign --force --sign - "$APP/Contents/Resources/com.codex.h3cvpn.helper"
codesign --force --sign - "$APP/Contents/Resources/H3CVPNUpdater"
codesign --force --deep --sign - "$APP"

cp -R "$APP" "$STAGE/SSL VPN Connect.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/README.md" "$STAGE/使用说明.md"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/第三方软件声明.md"
cp -R "$ROOT/Licenses" "$STAGE/开源许可证"

hdiutil create -volname "SSL VPN Connect" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT"
echo "Built: $OUTPUT"
