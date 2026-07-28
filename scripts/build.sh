#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VENDOR="$ROOT/.vendor"
OC="$VENDOR/openconnect-h3c"
BIND_PATCH="$ROOT/Patches/openconnect-macos-bound-interface.patch"
DIST="$ROOT/dist/H3CVPN-macos-arm64"
mkdir -p "$VENDOR" "$ROOT/dist"

if [ ! -d "$OC/.git" ]; then
    git clone --depth 1 --branch h3cssl https://gitlab.com/vimacs.hacks/openconnect.git "$OC"
fi
if [ ! -d "$VENDOR/vpnc-scripts/.git" ]; then
    git clone --depth 1 https://gitlab.com/openconnect/vpnc-scripts.git "$VENDOR/vpnc-scripts"
fi
if ! grep -q 'H3CVPN_BOUND_INTERFACE' "$OC/main.c"; then
    (cd "$OC" && patch -p1 < "$BIND_PATCH")
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
mkdir -p "$DIST/Resources"
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
cp "$OC/COPYING.LGPL" "$DIST/COPYING.LGPL"
cp "$VENDOR/vpnc-scripts/COPYING" "$DIST/COPYING.vpnc-scripts"
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
