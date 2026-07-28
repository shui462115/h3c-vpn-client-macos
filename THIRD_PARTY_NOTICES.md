# Third-Party Software Notices

SSL VPN Connect includes the third-party components listed below. The full
license texts are distributed in the `Licenses` directory in both the source
repository and the macOS package.

## OpenConnect H3C experimental branch

- Source: https://gitlab.com/vimacs.hacks/openconnect
- Commit: `22b2218d10e9cb3fb072db7f3e65c6fda44f68c0`
- License: GNU Lesser General Public License 2.1; individual files retain any
  more permissive or later-version notices stated in their source headers.
- Local modification: macOS outbound-interface binding support, documented in
  `Patches/openconnect-macos-bound-interface.patch`.

The built-in JSON parser used by this OpenConnect build is Copyright (C)
2012-2014 James McLaughlin et al. and is distributed under its BSD 2-Clause
license. See `Licenses/OpenConnect-JSON-BSD-2-Clause.txt`.

The complete corresponding OpenConnect source, including the local
modification, is included in the source archive attached alongside every
binary release. Recipients who receive the DMG outside GitHub must also be
given access to that source archive.

## vpnc-scripts

- Source: https://gitlab.com/openconnect/vpnc-scripts
- Commit: `ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101`
- License: GNU General Public License 2.0 or later.

The distributed `vpnc-script` is itself the complete, human-readable source
form of that component. Its full license is in
`Licenses/vpnc-scripts-GPL-2.0-or-later.txt`.

## OpenSSL

- Source: https://github.com/openssl/openssl
- Version: 3.6.3
- License: Apache License 2.0.
- License text: `Licenses/OpenSSL-Apache-2.0.txt`.

## libxml2

- Source: https://gitlab.gnome.org/GNOME/libxml2
- Version: 2.15.3
- License: MIT.
- Copyright (C) 1998-2012 Daniel Veillard and the Libxml2 Contributors.
- License text: `Licenses/libxml2-MIT.txt`.

## LZ4 library

- Source: https://github.com/lz4/lz4
- Version: 1.10.0
- License: BSD 2-Clause for the library files used by this application.
- Copyright (C) 2011-2023 Yann Collet.
- License text: `Licenses/LZ4-BSD-2-Clause.txt`.

## Trademark Notice

H3C and iNode are trademarks of their respective owners. SSL VPN Connect is
an independent, unofficial compatibility client. It is not affiliated with,
endorsed by, sponsored by, or distributed by H3C.
