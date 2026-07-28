#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OC="$ROOT/.vendor/openconnect-h3c"
VPNC="$ROOT/.vendor/vpnc-scripts"
OC_COMMIT=22b2218d10e9cb3fb072db7f3e65c6fda44f68c0
VPNC_COMMIT=ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/GUI/Info.plist")
OUTPUT=${1:-"$ROOT/dist/SSLVPNConnect-$VERSION-sources.tar.gz"}

if [ ! -d "$OC/.git" ] || [ ! -d "$VPNC/.git" ]; then
    echo "Build dependencies first with scripts/build.sh." >&2
    exit 1
fi
if [ "$(git -C "$OC" rev-parse HEAD)" != "$OC_COMMIT" ]; then
    echo "OpenConnect checkout does not match $OC_COMMIT." >&2
    exit 1
fi
if [ "$(git -C "$VPNC" rev-parse HEAD)" != "$VPNC_COMMIT" ]; then
    echo "vpnc-scripts checkout does not match $VPNC_COMMIT." >&2
    exit 1
fi
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
    echo "Commit project changes before creating the release source archive." >&2
    exit 1
fi

PROJECT_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ssl-vpn-connect-sources.XXXXXX")
PACKAGE="$STAGE/SSLVPNConnect-$VERSION-sources"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$PACKAGE/project" "$PACKAGE/third_party/openconnect" "$PACKAGE/third_party/vpnc-scripts"

git -C "$ROOT" archive --format=tar "$PROJECT_COMMIT" | tar -xf - -C "$PACKAGE/project"
git -C "$OC" archive --format=tar "$OC_COMMIT" | tar -xf - -C "$PACKAGE/third_party/openconnect"
git -C "$VPNC" archive --format=tar "$VPNC_COMMIT" | tar -xf - -C "$PACKAGE/third_party/vpnc-scripts"
patch -d "$PACKAGE/third_party/openconnect" -p1 < "$ROOT/Patches/openconnect-macos-bound-interface.patch"

/usr/bin/printf '%s\n' \
    "Project commit: $PROJECT_COMMIT" \
    "OpenConnect commit: $OC_COMMIT (local patch applied)" \
    "vpnc-scripts commit: $VPNC_COMMIT" \
    > "$PACKAGE/SOURCE-VERSIONS.txt"

mkdir -p "$(dirname -- "$OUTPUT")"
tar -czf "$OUTPUT" -C "$STAGE" "$(basename -- "$PACKAGE")"
echo "Built: $OUTPUT"
