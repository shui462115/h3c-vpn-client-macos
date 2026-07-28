#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VENDOR="$ROOT/.vendor"
OC="$VENDOR/openconnect-h3c"
BIND_PATCH="$ROOT/Patches/openconnect-macos-bound-interface.patch"
DIST="$ROOT/dist/H3CVPN-macos-arm64"
OC_COMMIT=22b2218d10e9cb3fb072db7f3e65c6fda44f68c0
VPNC_COMMIT=ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101
mkdir -p "$VENDOR" "$ROOT/dist"

if [ ! -d "$OC/.git" ]; then
    git clone --branch h3cssl https://gitlab.com/vimacs.hacks/openconnect.git "$OC"
    git -C "$OC" checkout --detach "$OC_COMMIT"
fi
if [ ! -d "$VENDOR/vpnc-scripts/.git" ]; then
    git clone https://gitlab.com/openconnect/vpnc-scripts.git "$VENDOR/vpnc-scripts"
    git -C "$VENDOR/vpnc-scripts" checkout --detach "$VPNC_COMMIT"
fi
if [ "$(git -C "$OC" rev-parse HEAD)" != "$OC_COMMIT" ]; then
    echo "OpenConnect checkout must be $OC_COMMIT" >&2
    exit 1
fi
if [ "$(git -C "$VENDOR/vpnc-scripts" rev-parse HEAD)" != "$VPNC_COMMIT" ]; then
    echo "vpnc-scripts checkout must be $VPNC_COMMIT" >&2
    exit 1
fi
if ! grep -q 'H3CVPN_BOUND_INTERFACE' "$OC/main.c"; then
    (cd "$OC" && patch -p1 < "$BIND_PATCH")
fi
if ! grep -q 'Modified by the SSL VPN Connect project on 2026-07-28' "$OC/main.c"; then
    echo "OpenConnect patch is missing its required modification notice." >&2
    exit 1
fi

export PATH="/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/libxml2/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I/opt/homebrew/opt/libxml2/include -I/opt/homebrew/opt/openssl@3/include ${CPPFLAGS:-}"
export LDFLAGS="-L/opt/homebrew/opt/libxml2/lib -L/opt/homebrew/opt/openssl@3/lib ${LDFLAGS:-}"

if [ ! -f "$OC/Makefile" ]; then
    (cd "$OC" && ./autogen.sh)
    (cd "$OC" && ./configure --with-openssl --without-gnutls --disable-nls --with-vpnc-script="$VENDOR/vpnc-scripts/vpnc-script" --prefix="$OC/dist")
fi
(cd "$OC" && make -j2 && make install)

rm -rf "$DIST"
mkdir -p "$DIST/Resources" "$DIST/Licenses"
clang -O2 -Wall -Wextra -Wpedantic "$ROOT/Sources/h3c-vpn.c" -o "$DIST/h3c-vpn"
cp "$OC/dist/sbin/openconnect" "$DIST/Resources/openconnect"
cp "$OC/dist/lib/libopenconnect.5.dylib" "$DIST/Resources/libopenconnect.5.dylib"
cp /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib "$DIST/Resources/libssl.3.dylib"
cp /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib "$DIST/Resources/libcrypto.3.dylib"
cp /opt/homebrew/opt/libxml2/lib/libxml2.16.dylib "$DIST/Resources/libxml2.16.dylib"
cp /opt/homebrew/opt/lz4/lib/liblz4.1.dylib "$DIST/Resources/liblz4.1.dylib"
cp "$VENDOR/vpnc-scripts/vpnc-script" "$DIST/Resources/vpnc-script"
cp "$ROOT/BUILD-INFO.txt" "$DIST/BUILD-INFO.txt"
cp "$ROOT/README.md" "$DIST/README.md"
cp "$ROOT/TEST-REPORT.md" "$DIST/TEST-REPORT.md"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$DIST/THIRD_PARTY_NOTICES.md"
cp "$ROOT/Licenses/"* "$DIST/Licenses/"
install_name_tool -change "$OC/dist/lib/libopenconnect.5.dylib" "@loader_path/libopenconnect.5.dylib" "$DIST/Resources/openconnect"
for binary in "$DIST/Resources/openconnect" "$DIST/Resources/libopenconnect.5.dylib"; do
    install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib "@loader_path/libssl.3.dylib" "$binary"
    install_name_tool -change /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib "@loader_path/libcrypto.3.dylib" "$binary"
    install_name_tool -change /opt/homebrew/opt/libxml2/lib/libxml2.16.dylib "@loader_path/libxml2.16.dylib" "$binary"
    install_name_tool -change /opt/homebrew/opt/lz4/lib/liblz4.1.dylib "@loader_path/liblz4.1.dylib" "$binary"
done
install_name_tool -id "@loader_path/libopenconnect.5.dylib" "$DIST/Resources/libopenconnect.5.dylib"
install_name_tool -id "@loader_path/libssl.3.dylib" "$DIST/Resources/libssl.3.dylib"
SSL_CRYPTO_PATH=$(otool -L "$DIST/Resources/libssl.3.dylib" | awk '/libcrypto\.3\.dylib/ { print $1; exit }')
install_name_tool -change "$SSL_CRYPTO_PATH" "@loader_path/libcrypto.3.dylib" "$DIST/Resources/libssl.3.dylib"
install_name_tool -id "@loader_path/libcrypto.3.dylib" "$DIST/Resources/libcrypto.3.dylib"
install_name_tool -id "@loader_path/libxml2.16.dylib" "$DIST/Resources/libxml2.16.dylib"
install_name_tool -id "@loader_path/liblz4.1.dylib" "$DIST/Resources/liblz4.1.dylib"
chmod 755 "$DIST/h3c-vpn" "$DIST/Resources/openconnect" "$DIST/Resources/vpnc-script" "$DIST/Resources/"*.dylib
codesign --force --sign - "$DIST/Resources/libcrypto.3.dylib"
codesign --force --sign - "$DIST/Resources/libssl.3.dylib"
codesign --force --sign - "$DIST/Resources/libxml2.16.dylib"
codesign --force --sign - "$DIST/Resources/liblz4.1.dylib"
codesign --force --sign - "$DIST/Resources/libopenconnect.5.dylib"
codesign --force --sign - "$DIST/Resources/openconnect"
codesign --force --sign - "$DIST/h3c-vpn"
echo "Built: $DIST"
