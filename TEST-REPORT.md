# Test report

Date: 2026-08-02

- Wrapper compiled with `clang -O2 -Wall -Wextra -Wpedantic` without warnings.
- `h3c-vpn --help`: passed.
- Gateway route detection: passed; detected `utun5` and refused by default.
- Dry run: passed; no password was requested and the pinned certificate was forwarded to the core.
- Bundled OpenConnect core started in a clean environment and reported `h3c` protocol support.
- All bundled Mach-O files are native `arm64`, have ad-hoc signatures, and have no absolute Homebrew or workspace library references.
- SwiftUI GUI compiled for native `arm64`, deployment target macOS 13.0, and was visually checked using an AppKit-hosted off-screen render.
- GUI includes gateway, username, secure password, route status, conflict warning, connect/disconnect, and live log controls.
- GUI now installs a restricted LaunchDaemon once; subsequent start/stop requests use a local peer-checked Unix socket without repeating authorization prompts.
- Helper installation enables a persistently disabled launchd service before bootstrap, preventing macOS error 5; copied privileged files have extended attributes cleared and the plist is linted before registration.
- Helper installation failures are copied to the connection log so the full launchctl error remains visible instead of being truncated in the authorization card.
- Fatal H3C TLS read errors now terminate the OpenConnect main loop instead of being counted as repeated work and spinning indefinitely.
- Each VPN child has an 8 MiB file-size limit, while the GUI reads at most the final 64 KiB of a log per refresh and stops an abnormal connection at the limit.
- GUI and helper use protocol version 5; an older helper is detected as outdated and cannot start a connection.
- The v0.9.2 failure was reproduced with a 26,581,454,384-byte log repeating `Read error on TLS session: 6`; process sampling showed the main thread in `refreshState()` and `configuredVPNAddress(from:)` with a 40.9 GiB physical footprint.
- The installed v0.9.3 GUI opened normally, rejected the installed protocol-v4 helper as outdated, and remained at 0.0% CPU with about 131 MiB RSS during the post-launch stability check.
- The v0.9.8 GUI checks the GitHub latest stable release asynchronously at launch and provides manual checks from both the application menu and menu-bar menu.
- Release parsing accepts only a newer three-component stable semantic version and the exact `SSLVPNConnect-macOS-arm64.dmg` asset from this repository's HTTPS GitHub release path.
- The updater requires GitHub's `sha256:` asset digest and expected byte count; correct data passed, while checksum and size mismatch fixtures were rejected before mounting.
- Mounted and staged applications must match bundle ID `com.codex.h3cvpn`, the expected release version, executable name, native arm64 architecture, and a deep strict code-signature check.
- Negative package tests rejected malformed release tags and digests, prereleases, wrong versions, a wrong bundle identifier, and a modified signed resource.
- The independent updater waited for the old PID, atomically exchanged two signed fixture application bundles in the same directory, removed the old bundle, and successfully reopened the replacement.
- Application updating is refused while VPN is connected; the privileged VPN helper is not silently replaced and retains its existing explicit action-time authorization flow.
- The final v0.9.8 app and bundled updater compiled without warnings for arm64 macOS 13.0, and the complete app passed deep strict code-signature verification.
- The v0.9.5 build integrates the generic LocalRouteManager UI and its version-6 LaunchDaemon installer; existing `~/Library/Application Support/LocalRouteManager/rules/*.conf` files are reused without adding default targets.
- Local route rule tests passed for IPv4/domain validation, optional DNS, enabled state, malformed targets, and missing interface input. The UI exposes the feature from the main network-path card, the menu-bar menu, and the application menu.
- The route service keeps one target per rule, migrates legacy multi-host files, validates the bound user-owned rule directory, refuses to replace foreign host routes, retains the last successful routes across transient DNS failures, protects pre-existing `/etc/resolver` files with an ownership marker, and reports enabled/managed/error counts through its status file. Saving against the current service does not request another administrator authorization.
- GUI preferences support optional local username and password persistence without accessing macOS Keychain; the preferences file is owner-only (`0600`).
- Gateway profiles include display name, endpoint, and pinned certificate; add/edit/remove/switch flows compile successfully.
- A fresh installation starts with a blank gateway placeholder; no gateway address or certificate pin is embedded in source or packaging metadata.
- Empty or invalid gateways skip route lookup, and connection requires a valid user-configured `pin-sha256` certificate fingerprint.
- Certificate probing invokes the bundled core in non-interactive authenticate-only mode and parses the advertised `pin-sha256` value without credentials.
- Enabling existing-utun routing skips route lookup and removes the route-conflict block for the next connection.
- The local-interface picker enumerates active non-loopback IPv4 interfaces and persists an automatic or explicit selection.
- The main window uses a two-way segmented switch between the VPN connection workspace and the local-route workspace; rule editing, interface selection, DNS, and apply actions stay in the main window.
- Rule files are mirrored to a user-only `rules-backup` directory and valid backups restore automatically when the primary rule directory is unexpectedly empty; unit tests cover this recovery path.
- The patched OpenConnect core bound a test socket to `en5` through macOS `IP_BOUND_IF` and emitted the expected binding log without transmitting credentials.
- Certificate fingerprint probing passes the gateway editor's selected local interface to the same patched OpenConnect core.
- Authentication, SSL, gateway, and script failures trigger automatic cleanup; connection establishment times out after 30 seconds without an assigned VPN address.
- A shared application model backs the main window and native menu-bar extra, allowing the window to close while VPN control remains available.
- A native 1024px icon master and complete multi-resolution `AppIcon.icns` are generated during packaging.
- Traffic accounting parses the assigned VPN IPv4 address, matches only its `utun` interface through `getifaddrs`, and samples inbound/outbound byte counters once per second.
- DMG checksum verification passed; the image mounted read-only, contained the app and Applications shortcut, and the app passed deep code-signature verification.
- Dependency commits are pinned and verified before building; release source archives contain the exact patched OpenConnect and vpnc-scripts source trees.
- The DMG and application resources include third-party notices plus the LGPL, GPL, Apache-2.0, MIT, and BSD license texts required by bundled components.
- Visible product branding uses `SSL VPN Connect`; H3C and iNode appear only in compatibility and trademark notices, and the generated icon contains no vendor logo.
- OpenConnect upstream unit tests: 4 passed, 1 failed. The failing `bad_dtls_test` uses an old Cisco DTLS case rejected by OpenSSL 3.6 (`no protocols available`). The H3C implementation in this package is TLS-only and does not use that DTLS path.

Not performed:

- No username/password was transmitted.
- No live H3C login or route installation was attempted.
- OTP, certificate, SMS, and custom authentication are not implemented by the experimental H3C core.
