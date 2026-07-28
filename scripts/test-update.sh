#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
BUILD="$ROOT/dist/update-test"
APP="$ROOT/dist/gui-build/SSL VPN Connect.app"
DMG="$ROOT/dist/SSLVPNConnect-macOS-arm64.dmg"

if [ ! -d "$APP" ] || [ ! -f "$DMG" ]; then
    echo "Build the DMG first with scripts/build-dmg.sh." >&2
    exit 1
fi

mkdir -p "$ROOT/.module-cache" "$BUILD"
export CLANG_MODULE_CACHE_PATH="$ROOT/.module-cache"

swiftc -sdk "$SDK" -target arm64-apple-macosx13.0 -warnings-as-errors \
    "$ROOT/GUI/H3CVPNUpdate.swift" "$ROOT/Tests/UpdateVersionTests.swift" \
    -o "$BUILD/UpdateVersionTests"
"$BUILD/UpdateVersionTests"

swiftc -sdk "$SDK" -target arm64-apple-macosx13.0 -warnings-as-errors \
    "$ROOT/GUI/H3CVPNUpdate.swift" "$ROOT/Tests/UpdatePackageTests.swift" \
    -o "$BUILD/UpdatePackageTests"
DIGEST=$(shasum -a 256 "$DMG" | awk '{print $1}')
"$BUILD/UpdatePackageTests" "$APP" "$DMG" "$DIGEST"

swiftc -sdk "$SDK" -target arm64-apple-macosx13.0 -warnings-as-errors \
    "$ROOT/Tests/UpdaterFixtureApp.swift" -framework AppKit \
    -o "$BUILD/UpdaterFixtureApp"
swiftc -sdk "$SDK" -target arm64-apple-macosx13.0 -warnings-as-errors -parse-as-library \
    "$ROOT/Tests/UpdaterIntegrationTests.swift" \
    -o "$BUILD/UpdaterIntegrationTests"
"$BUILD/UpdaterIntegrationTests" "$APP/Contents/Resources/H3CVPNUpdater" \
    "$BUILD/UpdaterFixtureApp"
